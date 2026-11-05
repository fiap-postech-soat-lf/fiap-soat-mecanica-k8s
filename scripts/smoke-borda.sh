#!/usr/bin/env bash
# Smoke da borda: verificacoes 5-14 (F2 + CP1). API Gateway + Lambda Authorizer + NLB +
# Traefik + Identity, incluindo os logins reais do Identity (10-14). Imprime PASS/FAIL.
#
# Uso: scripts/smoke-borda.sh
# Le do SSM /mecanica/auth/api-url, /mecanica/k8s/nlb-dns e /mecanica/identity/jwt-secret-arn.
# A chave privada do Identity vai para um arquivo temporario 0600, apagado na saida, e assina
# os tokens com local/jwt/gerar-token-dev.sh. Os dois POST de login so leem: nao altera nada.
# Saida: 0 se tudo passar, 1 se alguma verificacao falhar.
# Variaveis: AWS_REGION (padrao us-east-1)
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GERAR_TOKEN="$(dirname "$DIR")/local/jwt/gerar-token-dev.sh"
CHAVE_DEV="$(dirname "$DIR")/local/jwt/dev-private.pem"
export AWS_DEFAULT_REGION="${AWS_REGION:-us-east-1}"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
umask 077

# Dados do seed do Identity (V5__seed.sql em fiap-soat-mecanica-identity).
CPF_SEED="52998224725"
CLIENTE_ID_SEED="33333333-3333-3333-3333-333333333333"
VEICULO_ID_SEED="44444444-4444-4444-4444-444444444444"
EMAIL_MECANICO_SEED="mecanico@mecanica.test"
SENHA_SEED="Senha@123"
CPF_VALIDO_NAO_CADASTRADO="39053344705"

ssm() { aws ssm get-parameter --name "$1" --query Parameter.Value --output text; }

API=$(ssm /mecanica/auth/api-url)
API="${API%/}"
NLB=$(ssm /mecanica/k8s/nlb-dns)
aws secretsmanager get-secret-value --secret-id "$(ssm /mecanica/identity/jwt-secret-arn)" \
  --query SecretString --output text | jq -r .privateKeyPem > "$TMP/identity.pem"

# Chave que nao e a do Identity: a de dev, se existir; senao uma descartavel.
if [[ -f "$CHAVE_DEV" ]]; then
  OUTRA_CHAVE="$CHAVE_DEV"
else
  OUTRA_CHAVE="$TMP/outra.pem"
  openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "$OUTRA_CHAVE" 2> /dev/null
fi

SUB=$(cat /proc/sys/kernel/random/uuid 2> /dev/null || uuidgen | tr '[:upper:]' '[:lower:]')
TOKEN_VALIDO=$(CHAVE_PRIVADA="$TMP/identity.pem" "$GERAR_TOKEN" MECANICO "$SUB")
TOKEN_OUTRA_CHAVE=$(CHAVE_PRIVADA="$OUTRA_CHAVE" "$GERAR_TOKEN" MECANICO)
TOKEN_EXPIRADO=$(CHAVE_PRIVADA="$TMP/identity.pem" EMITIDO_HA_SEGUNDOS=7200 "$GERAR_TOKEN" MECANICO)

echo "API: $API"
echo "NLB: http://$NLB"
echo

FALHAS=0
pass() { printf 'PASS  %-4s %s (%s)\n' "$1" "$2" "$3"; }
fail() { printf 'FAIL  %-4s %s (%s)\n' "$1" "$2" "$3"; FALHAS=$((FALHAS + 1)); }

# requisitar <nome> <url> [args do curl...]: corpo e cabecalhos em $TMP/<nome>.*; imprime o status.
requisitar() {
  local nome="$1" url="$2"
  shift 2
  curl --silent --show-error --max-time 20 --retry 3 --retry-delay 2 \
    --output "$TMP/$nome.corpo" --dump-header "$TMP/$nome.cab" --write-out '%{http_code}' \
    "$@" "$url" || true
}

# conferir_status <id> <descricao> <esperado> <obtido>
conferir_status() {
  if [[ "$4" == "$3" ]]; then pass "$1" "$2" "HTTP $4"; else fail "$1" "$2" "esperado $3, obtido $4"; fi
}

# 5. Sem token: o API Gateway responde 401 sem invocar a Lambda.
status=$(requisitar s5 "$API/health-echo")
conferir_status 5 "sem token -> 401" 401 "$status"

# 6. Token invalido: o authorizer nega (resposta simples isAuthorized=false -> 403).
status=$(requisitar s6a "$API/health-echo" -H "Authorization: Bearer $TOKEN_OUTRA_CHAVE")
conferir_status 6a "token assinado com outra chave -> 403" 403 "$status"
status=$(requisitar s6b "$API/health-echo" -H "Authorization: Bearer $TOKEN_EXPIRADO")
conferir_status 6b "token expirado -> 403" 403 "$status"

# 7. Token valido: o whoami devolve os headers que o API Gateway injetou.
status=$(requisitar s7 "$API/health-echo" -H "Authorization: Bearer $TOKEN_VALIDO")
request_id=$(grep -i '^apigw-requestid:' "$TMP/s7.cab" | awk '{print $2}' | tr -d '\r' || true)
faltando=()
for esperado in "X-User-Sub: $SUB" "X-User-Principal-Type: FUNCIONARIO" "X-User-Cargo: MECANICO"; do
  grep -qiF "$esperado" "$TMP/s7.corpo" || faltando+=("$esperado")
done
if [[ -z "$request_id" ]] || ! grep -qiF "X-Correlation-Id: $request_id" "$TMP/s7.corpo"; then
  faltando+=("X-Correlation-Id = apigw-requestid (${request_id:-ausente})")
fi
if [[ "$status" != 200 ]]; then
  fail 7 "token valido -> 200 do whoami" "obtido $status"
elif [[ ${#faltando[@]} -gt 0 ]]; then
  fail 7 "token valido -> 200 do whoami" "faltando: $(IFS='; '; echo "${faltando[*]}")"
else
  pass 7 "token valido -> 200 do whoami com x-user-* e x-correlation-id" "HTTP 200"
fi

# 8. Rota publica com StripPrefix ate o Identity.
status=$(requisitar s8 "$API/identity/actuator/health")
if [[ "$status" == 200 ]] && grep -q '"UP"' "$TMP/s8.corpo"; then
  pass 8 "GET /identity/actuator/health sem token -> UP" "HTTP 200"
else
  fail 8 "GET /identity/actuator/health sem token -> UP" "obtido $status: $(head -c 200 "$TMP/s8.corpo")"
fi

# 9. Cadeia completa ate o servico, e defesa em profundidade no acesso direto ao NLB.
status=$(requisitar s9a "$API/clientes")
conferir_status 9a "GET /clientes sem token -> 401 do API Gateway" 401 "$status"

status=$(requisitar s9c "http://$NLB/clientes" \
  -H "x-user-sub: $SUB" -H "x-user-principal-type: FUNCIONARIO" -H "x-user-cargo: ATENDENTE")
conferir_status 9c "NLB direto, sem token e com x-user-* forjado -> 401 do Identity" 401 "$status"

# 10-14: logins reais do Identity (CP1). O token do Identity precisa passar pelo authorizer.
# post_json <nome> <url> <corpo> [args do curl...]
post_json() {
  local nome="$1" url="$2" corpo="$3"
  shift 3
  requisitar "$nome" "$url" -X POST -H 'Content-Type: application/json' --data "$corpo" "$@"
}

# 10. Login por CPF com o cliente do seed.
status=$(post_json s10 "$API/auth/cpf" "{\"cpf\":\"$CPF_SEED\"}")
TOKEN_CLIENTE=$(jq -r '.accessToken // empty' "$TMP/s10.corpo" 2> /dev/null || true)
if [[ "$status" == 200 && -n "$TOKEN_CLIENTE" && "$(jq -r .tokenType "$TMP/s10.corpo")" == Bearer ]]; then
  pass 10 "POST /auth/cpf com o CPF do seed -> 200 e Bearer" "HTTP 200"
else
  fail 10 "POST /auth/cpf com o CPF do seed -> 200 e Bearer" "obtido $status: $(head -c 200 "$TMP/s10.corpo")"
fi

# 11. O authorizer aceita o token emitido pelo Identity (prova do CP1).
status=$(requisitar s11 "$API/health-echo" -H "Authorization: Bearer $TOKEN_CLIENTE")
if [[ "$status" == 200 ]] && grep -qiF "X-User-Principal-Type: CLIENTE" "$TMP/s11.corpo" \
  && grep -qiF "X-User-Sub: $CLIENTE_ID_SEED" "$TMP/s11.corpo"; then
  pass 11 "token do Identity passa pelo authorizer (CLIENTE, sub do seed)" "HTTP 200"
else
  fail 11 "token do Identity passa pelo authorizer (CLIENTE, sub do seed)" "obtido $status: $(head -c 200 "$TMP/s11.corpo")"
fi

# 12. GET /clientes/me: 200 para o cliente; 403 do Identity (ErrorResponse) para um mecanico.
status=$(requisitar s12a "$API/clientes/me" -H "Authorization: Bearer $TOKEN_CLIENTE")
if [[ "$status" == 200 ]] && [[ "$(jq -r .id "$TMP/s12a.corpo" 2> /dev/null)" == "$CLIENTE_ID_SEED" ]]; then
  pass 12a "GET /clientes/me com o token do cliente -> 200 com o id do seed" "HTTP 200"
else
  fail 12a "GET /clientes/me com o token do cliente -> 200 com o id do seed" "obtido $status: $(head -c 200 "$TMP/s12a.corpo")"
fi
status=$(requisitar s12b "$API/clientes/me" -H "Authorization: Bearer $TOKEN_VALIDO")
if [[ "$status" == 403 ]] && jq -e '.status == 403 and has("erro")' "$TMP/s12b.corpo" > /dev/null 2>&1; then
  pass 12b "GET /clientes/me com token de mecanico -> 403 do Identity" "HTTP 403"
else
  fail 12b "GET /clientes/me com token de mecanico -> 403 do Identity" "obtido $status: $(head -c 200 "$TMP/s12b.corpo")"
fi

# 13. Login de staff e GET /veiculos/{id} com MECANICO (F3-a).
status=$(post_json s13a "$API/auth/login" "{\"email\":\"$EMAIL_MECANICO_SEED\",\"senha\":\"$SENHA_SEED\"}")
TOKEN_MECANICO=$(jq -r '.accessToken // empty' "$TMP/s13a.corpo" 2> /dev/null || true)
conferir_status 13a "POST /auth/login como mecanico -> 200" 200 "$status"
status=$(requisitar s13b "$API/veiculos/$VEICULO_ID_SEED" -H "Authorization: Bearer $TOKEN_MECANICO")
conferir_status 13b "GET /veiculos/{id} com token de mecanico -> 200" 200 "$status"

# 14. Erros de login sem enumeracao: CPF desconhecido -> 401; CPF malformado -> 400.
status=$(post_json s14a "$API/auth/cpf" "{\"cpf\":\"$CPF_VALIDO_NAO_CADASTRADO\"}")
conferir_status 14a "POST /auth/cpf valido e nao cadastrado -> 401" 401 "$status"
status=$(post_json s14b "$API/auth/cpf" '{"cpf":"123"}')
conferir_status 14b "POST /auth/cpf malformado -> 400" 400 "$status"

echo
if [[ "$FALHAS" -eq 0 ]]; then
  echo "Smoke da borda: tudo OK."
  exit 0
fi
echo "Smoke da borda: $FALHAS falha(s)."
exit 1
