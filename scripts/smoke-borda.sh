#!/usr/bin/env bash
# Smoke da borda (verificacoes 5 a 9 da secao 10 do plano da F2): API Gateway + Lambda
# Authorizer + NLB + Traefik + Identity. Imprime PASS/FAIL por verificacao.
#
# Uso: scripts/smoke-borda.sh
# Le do SSM /mecanica/auth/api-url, /mecanica/k8s/nlb-dns e /mecanica/identity/jwt-secret-arn.
# A chave privada do Identity vai para um arquivo temporario 0600, apagado na saida, e assina
# os tokens com local/jwt/gerar-token-dev.sh. So faz GET: nao altera nada.
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

# 404 do Identity (passou do authorizer e do JwtAuthenticationFilter), nao o do Traefik.
status=$(requisitar s9b "$API/clientes" -H "Authorization: Bearer $TOKEN_VALIDO")
if [[ "$status" == 404 ]] && ! grep -q '404 page not found' "$TMP/s9b.corpo"; then
  pass 9b "GET /clientes com token -> 404 do Identity" "HTTP 404"
else
  fail 9b "GET /clientes com token -> 404 do Identity" "obtido $status: $(head -c 200 "$TMP/s9b.corpo")"
fi

status=$(requisitar s9c "http://$NLB/clientes" \
  -H "x-user-sub: $SUB" -H "x-user-principal-type: FUNCIONARIO" -H "x-user-cargo: ATENDENTE")
conferir_status 9c "NLB direto, sem token e com x-user-* forjado -> 401 do Identity" 401 "$status"

echo
if [[ "$FALHAS" -eq 0 ]]; then
  echo "Smoke da borda: tudo OK."
  exit 0
fi
echo "Smoke da borda: $FALHAS falha(s)."
exit 1
