#!/usr/bin/env bash
# Demo da Saga com o Billing real e o Mercado Pago no EKS (F6-l). ESCREVE DADOS: abre tres OS de
# verdade, aprova e paga orcamentos, da baixa real no estoque e cancela uma OS. Nao rodar contra um
# ambiente que nao seja descartavel. O smoke-borda.sh, esse sim, so le (F3-k). Prova do DoD da F6.
#
# Os pagamentos (passos 6 e 8) e a recusa (passo 7) sao feitos A MAO no navegador: o script imprime o
# link e espera. Dados do pagamento manual (plano da F6, secao 11.1; o script nao os usa):
#   navegador: janela anonima, logada com o comprador de teste 3808343986
#   cartao: Mastercard 5031 4332 1540 6351, CVV 123, validade 11/30, documento CPF 12345678909
#   titular: APRO (aprovado) ou OTHE (recusado por erro geral)
#
# Passos:
#   1. logins do atendente, do mecanico e do almoxarife do seed e do cliente por CPF (52998224725)
#   2. estoque da peca do seed (qtdEstoque E0)
#   3. OS A ate AGUARDANDO_APROVACAO (abertura, prestacao, peca, conclusao); o cliente le o orcamento
#      GERADO com valorTotal 159.80 e expiraEm ~ agora + 24 h
#   4. um CLIENTE com outro sub tenta aprovar -> 403 ORCAMENTO_DE_OUTRO_CLIENTE
#   5. o cliente do seed aprova -> 200 APROVADO; a OS vai a EM_EXECUCAO e o estoque cai 2 (baixa real)
#   6. o mecanico finaliza a prestacao; a OS vai a AGUARDANDO_PAGAMENTO e o cliente le o pagamento
#      PENDENTE com o link; PAGAMENTO APRO a mao; a OS vai a ENTREGUE, a Saga a CONCLUIDA e o pagamento
#      a APROVADO
#   7. OS B ate AGUARDANDO_PAGAMENTO (o atendente aprova em nome do cliente); PAGAMENTO OTHE a mao: o
#      pagamento vira RECUSADO com motivo, a OS continua AGUARDANDO_PAGAMENTO e o historico mostra o motivo
#   8. POST /pagamentos/{osB}/nova-cobranca -> 201 com link novo e o antigo SUBSTITUIDO; PAGAMENTO APRO a
#      mao no link novo; a OS B vai a ENTREGUE
#   9. OS C ate AGUARDANDO_APROVACAO; o cliente recusa -> 200 RECUSADO; a OS vai a CANCELADA, a Saga a
#      COMPENSADA e o estoque disponivel volta ao valor de antes da OS C
#  10. as DLQs mecanica-billing-comandos-dlq e mecanica-os-saga-respostas-dlq com 0 mensagens e o log do
#      Billing (30 min) sem mensagem_falhou nem webhook_assinatura_invalida
#
# Uso: scripts/demo-saga-billing.sh [--so-apro] [--help]
#   --so-apro: roda so os passos 1-6 e 10 (uma OS ate ENTREGUE com APRO + simulador do painel) e pula os
#              passos 7-9 (OTHE, nova cobranca e recusa), que o E2E e a F6 ja cobrem (F7-j)
# Le do SSM /mecanica/auth/api-url e /mecanica/identity/jwt-secret-arn; usa as filas pelo nome e kubectl
# (kubeconfig do cluster: aws eks update-kubeconfig --name <cluster>) para o log. A chave privada do
# Identity vai para um arquivo temporario 0600, apagado na saida, e assina o token do passo 4.
# Saida: 0 se tudo passar, 1 se algum passo falhar.
# Variaveis: AWS_REGION (padrao us-east-1), NAMESPACE (padrao mecanica),
#            PAGAMENTO_TIMEOUT (segundos de espera de cada pagamento a mao e do polling, padrao 600)
set -euo pipefail

SO_APRO=false
for arg in "$@"; do
  case "$arg" in
    --so-apro) SO_APRO=true ;;
    -h | --help)
      sed -n '2,/^set -euo/p' "${BASH_SOURCE[0]}" | grep '^#' | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *) echo "Argumento desconhecido: $arg" >&2; exit 1 ;;
  esac
done

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GERAR_TOKEN="$(dirname "$DIR")/local/jwt/gerar-token-dev.sh"
export AWS_DEFAULT_REGION="${AWS_REGION:-us-east-1}"
NAMESPACE="${NAMESPACE:-mecanica}"
PAGAMENTO_TIMEOUT="${PAGAMENTO_TIMEOUT:-600}"

# Dados do seed do Identity (V5__seed.sql), do OS (V6__seed.sql) e do Execucao (SeedPecas).
CPF_SEED="52998224725"
EMAIL_ATENDENTE_SEED="atendente@mecanica.test"
EMAIL_MECANICO_SEED="mecanico@mecanica.test"
EMAIL_ALMOXARIFE_SEED="almoxarife@mecanica.test"
SENHA_SEED="Senha@123"
VEICULO_ID_SEED="44444444-4444-4444-4444-444444444444"
SERVICO_ID_SEED="77777777-7777-7777-7777-777777777777"
PECA_ID_SEED="55555555-5555-5555-5555-555555555555"
PRECO_MAO_DE_OBRA="80.00"
QUANTIDADE=2
# 80,00 + 2 x 39,90 (valorUnitario do Filtro de Oleo)
VALOR_TOTAL_ESPERADO="159.80"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
umask 077

ssm() { aws ssm get-parameter --name "$1" --query Parameter.Value --output text; }
passo() { printf 'PASS  %-3s %s\n' "$1" "$2"; }
falhar() {
  printf 'FAIL  %-3s %s\n' "$1" "$2" >&2
  exit 1
}

# api <token> <metodo> <caminho> [corpo]: devolve o corpo em $TMP/resp.json e imprime o status HTTP.
api() {
  local token="$1" metodo="$2" caminho="$3" corpo="${4:-}"
  local args=(--silent --show-error --max-time 20 --output "$TMP/resp.json" --write-out '%{http_code}'
    -X "$metodo" -H 'Content-Type: application/json' -H "Authorization: Bearer $token")
  [[ -n "$corpo" ]] && args+=(--data "$corpo")
  curl "${args[@]}" "$API$caminho" || true
}

# resumo: o inicio do corpo da ultima resposta, para as mensagens de falha.
resumo() { head -c 300 "$TMP/resp.json" 2> /dev/null || true; }

# login <email>: imprime o accessToken.
login() {
  local status
  status=$(curl --silent --show-error --max-time 20 --output "$TMP/login.json" --write-out '%{http_code}' \
    -X POST -H 'Content-Type: application/json' \
    --data "{\"email\":\"$1\",\"senha\":\"$SENHA_SEED\"}" "$API/auth/login" || true)
  [[ "$status" == 200 ]] || return 1
  jq -er '.accessToken' "$TMP/login.json"
}

# esperar <tentativas> <intervalo> <comando...>: repete o comando ate ele sair com 0.
esperar() {
  local tentativas="$1" intervalo="$2"
  shift 2
  local i
  for ((i = 1; i <= tentativas; i++)); do
    "$@" && return 0
    sleep "$intervalo"
  done
  return 1
}

# Tentativas de 5 s que cobrem o PAGAMENTO_TIMEOUT (pagamento a mao + webhook).
tentativas_pagamento() { echo $(((PAGAMENTO_TIMEOUT + 4) / 5)); }

# Consultas usadas nas esperas e nas conferencias (cada uma devolve 0 quando a condicao vale).
campo_os() { # campo_os <osId> <campo>: imprime o campo da OS (atendente)
  [[ "$(api "$TOKEN_ATENDENTE" GET "/ordem-servicos/$1")" == 200 ]] && jq -r ".$2 // empty" "$TMP/resp.json"
}
os_tem() { [[ "$(campo_os "$1" "$2")" == "$3" ]]; } # os_tem <osId> <campo> <valor>
estoque() { # estoque <campo>: qtdEstoque ou qtdDisponivel da peca do seed (almoxarife)
  [[ "$(api "$TOKEN_ALMOXARIFE" GET "/pecas/$PECA_ID_SEED")" == 200 ]] && jq -er ".$1" "$TMP/resp.json"
}
estoque_e() { [[ "$(estoque "$1")" == "$2" ]]; } # estoque_e <campo> <valor>
orcamento_tem() { # orcamento_tem <osId> <status>: orcamento da OS no Billing (atendente)
  [[ "$(api "$TOKEN_ATENDENTE" GET "/orcamentos/por-os/$1")" == 200 ]] \
    && [[ "$(jq -r '.status // empty' "$TMP/resp.json")" == "$2" ]]
}
pagamento_tem() { # pagamento_tem <osId> <status>: status do pagamento vigente (cliente)
  [[ "$(api "$TOKEN_CLIENTE" GET "/pagamentos/por-os/$1")" == 200 ]] \
    && [[ "$(jq -r '.vigente.status // empty' "$TMP/resp.json")" == "$2" ]]
}

abrir_os() { # abrir_os <descricao>: imprime o id da OS RECEBIDA
  local status
  status=$(api "$TOKEN_ATENDENTE" POST /ordem-servicos "{\"veiculoId\":\"$VEICULO_ID_SEED\",\"observacao\":\"$1\"}")
  [[ "$status" == 201 && "$(jq -r .situacao "$TMP/resp.json")" == RECEBIDA ]] || return 1
  jq -r .id "$TMP/resp.json"
}

# preparar_os <passo> <descricao>: leva uma OS nova ate AGUARDANDO_APROVACAO (diagnostico com a
# prestacao de 80.00 e 2 Filtros de Oleo = 159.80). Preenche OS_ID, PRESTACAO_ID e ORCAMENTO_ID.
preparar_os() {
  local p="$1" status
  OS_ID=$(abrir_os "$2") || falhar "$p" "POST /ordem-servicos: $(resumo)"
  esperar 15 2 os_tem "$OS_ID" situacao EM_DIAGNOSTICO \
    || falhar "$p" "OS $OS_ID continua $(campo_os "$OS_ID" situacao || true) (esperado EM_DIAGNOSTICO)"
  status=$(api "$TOKEN_MECANICO" POST "/execucoes/$OS_ID/prestacoes" \
    "{\"servicoId\":\"$SERVICO_ID_SEED\",\"precoMaoDeObra\":$PRECO_MAO_DE_OBRA}")
  [[ "$status" == 201 ]] || falhar "$p" "POST /prestacoes: HTTP $status: $(resumo)"
  PRESTACAO_ID=$(jq -r .id "$TMP/resp.json")
  status=$(api "$TOKEN_ALMOXARIFE" POST "/execucoes/$OS_ID/prestacoes/$PRESTACAO_ID/pecas" \
    "{\"pecaId\":\"$PECA_ID_SEED\",\"quantidade\":$QUANTIDADE}")
  [[ "$status" == 201 ]] || falhar "$p" "POST /pecas da prestacao: HTTP $status: $(resumo)"
  status=$(api "$TOKEN_MECANICO" PATCH "/execucoes/$OS_ID/diagnostico/concluir")
  [[ "$status" == 200 ]] || falhar "$p" "PATCH /diagnostico/concluir: HTTP $status: $(resumo)"
  esperar 15 2 os_tem "$OS_ID" situacao AGUARDANDO_APROVACAO \
    || falhar "$p" "OS $OS_ID continua $(campo_os "$OS_ID" situacao || true) (esperado AGUARDANDO_APROVACAO; confira o Billing e a DLQ mecanica-billing-comandos-dlq)"
  esperar 10 2 orcamento_tem "$OS_ID" GERADO || falhar "$p" "orcamento da OS $OS_ID nao esta GERADO: $(resumo)"
  ORCAMENTO_ID=$(jq -r .id "$TMP/resp.json")
}

# aprovar_como <token> <orcamentoId> <passo>: aprova o orcamento e confere 200 APROVADO.
aprovar_como() {
  local status
  status=$(api "$1" PATCH "/orcamentos/$2/aprovar")
  [[ "$status" == 200 && "$(jq -r .status "$TMP/resp.json")" == APROVADO ]] \
    || falhar "$3" "PATCH /orcamentos/$2/aprovar: HTTP $status: $(resumo)"
}

# finalizar_execucao <passo>: o mecanico finaliza a prestacao de OS_ID e a OS chega a AGUARDANDO_PAGAMENTO.
finalizar_execucao() {
  local status
  esperar 15 2 os_tem "$OS_ID" situacao EM_EXECUCAO \
    || falhar "$1" "OS $OS_ID continua $(campo_os "$OS_ID" situacao || true) (esperado EM_EXECUCAO)"
  status=$(api "$TOKEN_MECANICO" PATCH "/execucoes/$OS_ID/prestacoes/$PRESTACAO_ID/finalizar")
  [[ "$status" == 200 ]] || falhar "$1" "PATCH /prestacoes/$PRESTACAO_ID/finalizar: HTTP $status: $(resumo)"
  esperar 15 2 os_tem "$OS_ID" situacao AGUARDANDO_PAGAMENTO \
    || falhar "$1" "OS $OS_ID continua $(campo_os "$OS_ID" situacao || true) (esperado AGUARDANDO_PAGAMENTO)"
  esperar 10 2 pagamento_tem "$OS_ID" PENDENTE || falhar "$1" "pagamento da OS $OS_ID nao esta PENDENTE: $(resumo)"
  LINK=$(jq -er '.vigente.link' "$TMP/resp.json") || falhar "$1" "pagamento PENDENTE sem link: $(resumo)"
}

# pedir_pagamento <titular> <osId>: imprime o link (LINK) e espera o pagamento a mao.
pedir_pagamento() {
  printf '\n  >>> PAGAMENTO A MAO (%s) da OS %s\n  >>> Janela anonima, comprador de teste 3808343986; titular do cartao: %s\n  >>> %s\n\n' \
    "$1" "$2" "$1" "$LINK"
}

API=$(ssm /mecanica/auth/api-url)
API="${API%/}"
aws secretsmanager get-secret-value --secret-id "$(ssm /mecanica/identity/jwt-secret-arn)" \
  --query SecretString --output text | jq -r .privateKeyPem > "$TMP/identity.pem"
echo "API: $API"
echo

# 1. Logins do seed e do cliente por CPF.
TOKEN_ATENDENTE=$(login "$EMAIL_ATENDENTE_SEED") || falhar 1 "login do atendente"
TOKEN_MECANICO=$(login "$EMAIL_MECANICO_SEED") || falhar 1 "login do mecanico"
TOKEN_ALMOXARIFE=$(login "$EMAIL_ALMOXARIFE_SEED") || falhar 1 "login do almoxarife"
status=$(curl --silent --show-error --max-time 20 --output "$TMP/cpf.json" --write-out '%{http_code}' \
  -X POST -H 'Content-Type: application/json' --data "{\"cpf\":\"$CPF_SEED\"}" "$API/auth/cpf" || true)
[[ "$status" == 200 ]] || falhar 1 "POST /auth/cpf: HTTP $status"
TOKEN_CLIENTE=$(jq -er '.accessToken' "$TMP/cpf.json") || falhar 1 "POST /auth/cpf sem accessToken"
passo 1 "logins do atendente, do mecanico, do almoxarife e do cliente (CPF)"

# 2. Estoque inicial.
E0=$(estoque qtdEstoque) || falhar 2 "GET /pecas/$PECA_ID_SEED: $(resumo) (o SeedPecas rodou?)"
passo 2 "peca do seed com qtdEstoque E0 = $E0"

# 3. OS A ate AGUARDANDO_APROVACAO; o cliente le o orcamento.
preparar_os 3 "demo do Billing: OS A, paga com APRO (F6)"
OS_A="$OS_ID"
PRESTACAO_A="$PRESTACAO_ID"
ORCAMENTO_A="$ORCAMENTO_ID"
status=$(api "$TOKEN_CLIENTE" GET "/orcamentos/por-os/$OS_A")
[[ "$status" == 200 && "$(jq -r .status "$TMP/resp.json")" == GERADO ]] \
  || falhar 3 "GET /orcamentos/por-os/$OS_A com o token do cliente: HTTP $status: $(resumo)"
jq -e --argjson total "$VALOR_TOTAL_ESPERADO" '.valorTotal == $total' "$TMP/resp.json" > /dev/null \
  || falhar 3 "orcamento com valorTotal $(jq -r .valorTotal "$TMP/resp.json"), esperado $VALOR_TOTAL_ESPERADO"
EXPIRA=$(jq -r .expiraEm "$TMP/resp.json")
EXPIRA_S=$(date -d "$EXPIRA" +%s 2> /dev/null) || falhar 3 "expiraEm ilegivel: $EXPIRA"
FALTAM=$((EXPIRA_S - $(date +%s)))
((FALTAM > 23 * 3600 && FALTAM <= 24 * 3600 + 300)) \
  || falhar 3 "expiraEm $EXPIRA deveria ser ~24 h a frente (faltam $FALTAM s)"
passo 3 "OS A (osId $OS_A) AGUARDANDO_APROVACAO; orcamento $ORCAMENTO_A GERADO, $VALOR_TOTAL_ESPERADO, expira em ~24 h"

# 4. Outro CLIENTE nao aprova o orcamento do cliente do seed.
TOKEN_OUTRO=$(CHAVE_PRIVADA="$TMP/identity.pem" "$GERAR_TOKEN" CLIENTE) || falhar 4 "nao gerou o token do outro cliente"
status=$(api "$TOKEN_OUTRO" PATCH "/orcamentos/$ORCAMENTO_A/aprovar")
[[ "$status" == 403 && "$(jq -r .erro "$TMP/resp.json")" == ORCAMENTO_DE_OUTRO_CLIENTE ]] \
  || falhar 4 "esperado 403 ORCAMENTO_DE_OUTRO_CLIENTE, obtido HTTP $status: $(resumo)"
passo 4 "outro CLIENTE aprovando -> 403 ORCAMENTO_DE_OUTRO_CLIENTE"

# 5. O cliente do seed aprova: a Saga inicia a execucao e da baixa real no estoque.
aprovar_como "$TOKEN_CLIENTE" "$ORCAMENTO_A" 5
esperar 15 2 os_tem "$OS_A" situacao EM_EXECUCAO \
  || falhar 5 "OS $OS_A continua $(campo_os "$OS_A" situacao || true) (esperado EM_EXECUCAO)"
esperar 10 2 estoque_e qtdEstoque "$((E0 - QUANTIDADE))" \
  || falhar 5 "qtdEstoque $(estoque qtdEstoque || true), esperado $((E0 - QUANTIDADE)) (baixa real)"
passo 5 "orcamento APROVADO pelo cliente, OS EM_EXECUCAO e qtdEstoque $E0 -> $((E0 - QUANTIDADE))"

# 6. Finalizacao, cobranca e pagamento APRO a mao.
OS_ID="$OS_A"
PRESTACAO_ID="$PRESTACAO_A"
finalizar_execucao 6
pedir_pagamento APRO "$OS_A"
esperar "$(tentativas_pagamento)" 5 os_tem "$OS_A" situacao ENTREGUE \
  || falhar 6 "OS $OS_A continua $(campo_os "$OS_A" situacao || true) apos ${PAGAMENTO_TIMEOUT}s (o webhook chegou? confira o notifications_history e o log do Billing)"
esperar 15 2 os_tem "$OS_A" sagaStatus CONCLUIDA || falhar 6 "Saga da OS $OS_A: '$(campo_os "$OS_A" sagaStatus || true)', esperado CONCLUIDA"
esperar 10 2 pagamento_tem "$OS_A" APROVADO || falhar 6 "pagamento da OS $OS_A nao esta APROVADO: $(resumo)"
passo 6 "pagamento APRO -> pagamento APROVADO, OS ENTREGUE e Saga CONCLUIDA"

if ! $SO_APRO; then
  # 7. OS B: pagamento OTHE a mao e recusa.
  preparar_os 7 "demo do Billing: OS B, recusada com OTHE e nova cobranca (F6)"
  OS_B="$OS_ID"
  aprovar_como "$TOKEN_ATENDENTE" "$ORCAMENTO_ID" 7
  finalizar_execucao 7
  LINK_B1="$LINK"
  pedir_pagamento OTHE "$OS_B"
  esperar "$(tentativas_pagamento)" 5 pagamento_tem "$OS_B" RECUSADO \
    || falhar 7 "pagamento da OS $OS_B continua '$(jq -r '.vigente.status // empty' "$TMP/resp.json")' apos ${PAGAMENTO_TIMEOUT}s (esperado RECUSADO)"
  MOTIVO=$(jq -er '.vigente.motivo | select(length > 0)' "$TMP/resp.json") || falhar 7 "pagamento RECUSADO sem motivo: $(resumo)"
  os_tem "$OS_B" situacao AGUARDANDO_PAGAMENTO || falhar 7 "OS $OS_B saiu de AGUARDANDO_PAGAMENTO: $(campo_os "$OS_B" situacao || true)"
  status=$(api "$TOKEN_ATENDENTE" GET "/ordem-servicos/$OS_B/historico")
  [[ "$status" == 200 ]] || falhar 7 "GET /ordem-servicos/$OS_B/historico: HTTP $status: $(resumo)"
  jq -e --arg m "$MOTIVO" 'any(.[]; (.motivo // "") | contains($m))' "$TMP/resp.json" > /dev/null \
    || falhar 7 "o historico da OS $OS_B nao mostra o motivo '$MOTIVO': $(resumo)"
  passo 7 "pagamento OTHE -> RECUSADO (motivo '$MOTIVO'), OS B continua AGUARDANDO_PAGAMENTO e o historico mostra o motivo"

  # 8. Nova cobranca e pagamento APRO a mao.
  status=$(api "$TOKEN_ATENDENTE" POST "/pagamentos/$OS_B/nova-cobranca")
  [[ "$status" == 201 ]] || falhar 8 "POST /pagamentos/$OS_B/nova-cobranca: HTTP $status: $(resumo)"
  LINK=$(jq -er '.link' "$TMP/resp.json") || falhar 8 "nova cobranca sem link: $(resumo)"
  [[ "$LINK" != "$LINK_B1" ]] || falhar 8 "a nova cobranca devolveu o mesmo link"
  status=$(api "$TOKEN_CLIENTE" GET "/pagamentos/por-os/$OS_B")
  [[ "$status" == 200 && "$(jq -r '.vigente.status' "$TMP/resp.json")" == PENDENTE ]] \
    || falhar 8 "pagamento vigente da OS $OS_B: HTTP $status: $(resumo)"
  jq -e '[.historico[] | select(.status == "SUBSTITUIDO")] | length == 1' "$TMP/resp.json" > /dev/null \
    || falhar 8 "o historico da OS $OS_B deveria ter 1 cobranca SUBSTITUIDO: $(resumo)"
  pedir_pagamento APRO "$OS_B"
  esperar "$(tentativas_pagamento)" 5 os_tem "$OS_B" situacao ENTREGUE \
    || falhar 8 "OS $OS_B continua $(campo_os "$OS_B" situacao || true) apos ${PAGAMENTO_TIMEOUT}s (esperado ENTREGUE)"
  passo 8 "nova cobranca 201 (antigo SUBSTITUIDO) -> pagamento APRO -> OS B ENTREGUE"

  # 9. OS C: o cliente recusa o orcamento e a Saga compensa.
  D1=$(estoque qtdDisponivel) || falhar 9 "GET /pecas/$PECA_ID_SEED: $(resumo)"
  preparar_os 9 "demo do Billing: OS C, orcamento recusado (F6)"
  OS_C="$OS_ID"
  esperar 10 2 estoque_e qtdDisponivel "$((D1 - QUANTIDADE))" \
    || falhar 9 "qtdDisponivel $(estoque qtdDisponivel || true), esperado $((D1 - QUANTIDADE)) (reserva da OS C)"
  status=$(api "$TOKEN_CLIENTE" PATCH "/orcamentos/$ORCAMENTO_ID/recusar" '{"motivo":"demo: orcamento recusado"}')
  [[ "$status" == 200 && "$(jq -r .status "$TMP/resp.json")" == RECUSADO ]] \
    || falhar 9 "PATCH /orcamentos/$ORCAMENTO_ID/recusar: HTTP $status: $(resumo)"
  esperar 15 2 os_tem "$OS_C" situacao CANCELADA \
    || falhar 9 "OS $OS_C continua $(campo_os "$OS_C" situacao || true) (esperado CANCELADA)"
  esperar 15 2 os_tem "$OS_C" sagaStatus COMPENSADA || falhar 9 "Saga da OS $OS_C: '$(campo_os "$OS_C" sagaStatus || true)', esperado COMPENSADA"
  esperar 10 2 estoque_e qtdDisponivel "$D1" || falhar 9 "qtdDisponivel $(estoque qtdDisponivel || true), esperado $D1 (compensacao)"
  passo 9 "orcamento RECUSADO -> OS C CANCELADA, Saga COMPENSADA e qtdDisponivel de volta a $D1"
fi

# 10. Nada ficou em DLQ e o Billing nao registrou falha.
for dlq in mecanica-billing-comandos-dlq mecanica-os-saga-respostas-dlq; do
  url=$(aws sqs get-queue-url --queue-name "$dlq" --query QueueUrl --output text) || falhar 10 "fila $dlq nao existe"
  total=$(aws sqs get-queue-attributes --queue-url "$url" --attribute-names ApproximateNumberOfMessages \
    --query Attributes.ApproximateNumberOfMessages --output text)
  [[ "$total" == 0 ]] || falhar 10 "$dlq com $total mensagem(ns)"
done
kubectl logs -l app=mecanica-billing -n "$NAMESPACE" --since=30m --tail=-1 > "$TMP/billing.log" 2> /dev/null \
  || falhar 10 "kubectl logs do Billing (confira o kubeconfig: aws eks update-kubeconfig --name <cluster>)"
if grep -qE 'mensagem_falhou|webhook_assinatura_invalida' "$TMP/billing.log"; then
  grep -E 'mensagem_falhou|webhook_assinatura_invalida' "$TMP/billing.log" | head -3 | cut -c1-240
  falhar 10 "mensagem_falhou ou webhook_assinatura_invalida no log do Billing"
fi
passo 10 "2 DLQs com 0 mensagens e o log do Billing limpo"

echo
if $SO_APRO; then
  echo "Demo da Saga com o Billing (--so-apro): tudo OK (OS A $OS_A)."
else
  echo "Demo da Saga com o Billing: tudo OK (OS A $OS_A, OS B $OS_B, OS C $OS_C)."
fi
