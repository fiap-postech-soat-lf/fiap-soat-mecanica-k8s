#!/usr/bin/env bash
# Demo da Saga com o Execucao real no EKS (F5-m). ESCREVE DADOS: abre duas OS de verdade, monta o
# diagnostico de uma delas com uma peca do seed, reserva e devolve estoque e cancela as duas. Nao
# rodar contra um ambiente que nao seja descartavel. O smoke-borda.sh, esse sim, so le (F3-k).
#
# Passos:
#   1. logins do atendente, do mecanico e do almoxarife do seed
#   2. GET /pecas/{peca} (almoxarife): anota qtdDisponivel (D0)
#   3. POST /ordem-servicos (atendente) com o veiculo do seed -> 201 RECEBIDA
#   4. a OS vai a EM_DIAGNOSTICO com o Execucao real (ate 30 s); GET /execucoes/{osId} e a fila a mostram
#   5. POST /execucoes/{osId}/prestacoes (mecanico) -> 201 com nomeServico do catalogo do OS (JWT repassado)
#   6. POST /execucoes/{osId}/prestacoes/{id}/pecas (almoxarife), quantidade 2 -> 201
#   7. PATCH /execucoes/{osId}/diagnostico/concluir (mecanico) -> 200 DIAGNOSTICO_CONCLUIDO
#   8. a OS chega a AGUARDANDO_APROVACAO, qtdDisponivel = D0 - 2 (reserva real) e o Billing real
#      guarda o orcamento GERADO com valorTotal 159.80 (GET /orcamentos/por-os/{osId}, F6-l)
#   9. PATCH /cancelar -> 200 CANCELADA; a Saga vai a COMPENSADA, qtdDisponivel volta a D0, o
#      orcamento fica CANCELADO e a ordem do Execucao fica CANCELADA e fora da fila
#  10. uma segunda OS, cancelada em EM_DIAGNOSTICO: a ordem do Execucao fica CANCELADA pela assinatura
#      filtrada do OrdemServicoCancelada (F5-b)
#  11. as 3 DLQs vazias e nenhum mensagem_falhou no log do Execucao
#
# Uso: scripts/demo-saga-execucao.sh
# Le do SSM /mecanica/auth/api-url, usa as DLQs pelo nome e kubectl (kubeconfig do cluster: aws eks update-kubeconfig --name <cluster>) para o log.
# Saida: 0 se tudo passar, 1 se algum passo falhar.
# Variaveis: AWS_REGION (padrao us-east-1), NAMESPACE (padrao mecanica)
set -euo pipefail

export AWS_DEFAULT_REGION="${AWS_REGION:-us-east-1}"
NAMESPACE="${NAMESPACE:-mecanica}"

# Dados do seed do Identity (V5__seed.sql), do OS (V6__seed.sql) e do Execucao (SeedPecas).
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

# Consultas usadas nas esperas e nas conferencias (cada uma devolve 0 quando a condicao vale).
campo_os() { # campo_os <osId> <campo>: imprime o campo da OS (atendente)
  [[ "$(api "$TOKEN_ATENDENTE" GET "/ordem-servicos/$1")" == 200 ]] && jq -r ".$2 // empty" "$TMP/resp.json"
}
os_tem() { [[ "$(campo_os "$1" "$2")" == "$3" ]]; } # os_tem <osId> <campo> <valor>
status_execucao() { # status_execucao <osId>: status da ordem no Execucao (mecanico)
  [[ "$(api "$TOKEN_MECANICO" GET "/execucoes/$1")" == 200 ]] && jq -r '.status // empty' "$TMP/resp.json"
}
execucao_tem() { [[ "$(status_execucao "$1")" == "$2" ]]; } # execucao_tem <osId> <status>
na_fila() { # na_fila <osId>: 0 se a ordem esta na fila de execucao
  [[ "$(api "$TOKEN_MECANICO" GET "/execucoes/fila?size=100")" == 200 ]] \
    && jq -e --arg os "$1" '.itens | map(.osId) | index($os) != null' "$TMP/resp.json" > /dev/null
}
disponivel() { # disponivel: qtdDisponivel da peca do seed (almoxarife)
  [[ "$(api "$TOKEN_ALMOXARIFE" GET "/pecas/$PECA_ID_SEED")" == 200 ]] && jq -er '.qtdDisponivel' "$TMP/resp.json"
}
status_orcamento() { # status_orcamento <osId>: status do orcamento da OS no Billing (atendente)
  [[ "$(api "$TOKEN_ATENDENTE" GET "/orcamentos/por-os/$1")" == 200 ]] && jq -r '.status // empty' "$TMP/resp.json"
}
orcamento_tem() { [[ "$(status_orcamento "$1")" == "$2" ]]; } # orcamento_tem <osId> <status>
disponivel_e() { [[ "$(disponivel)" == "$1" ]]; }

abrir_os() { # abrir_os <descricao>: imprime o id da OS RECEBIDA
  local status
  status=$(api "$TOKEN_ATENDENTE" POST /ordem-servicos "{\"veiculoId\":\"$VEICULO_ID_SEED\",\"observacao\":\"$1\"}")
  [[ "$status" == 201 && "$(jq -r .situacao "$TMP/resp.json")" == RECEBIDA ]] || return 1
  jq -r .id "$TMP/resp.json"
}

API=$(ssm /mecanica/auth/api-url)
API="${API%/}"
echo "API: $API"
echo

# 1. Logins do seed.
TOKEN_ATENDENTE=$(login "$EMAIL_ATENDENTE_SEED") || falhar 1 "login do atendente"
TOKEN_MECANICO=$(login "$EMAIL_MECANICO_SEED") || falhar 1 "login do mecanico"
TOKEN_ALMOXARIFE=$(login "$EMAIL_ALMOXARIFE_SEED") || falhar 1 "login do almoxarife"
passo 1 "logins do atendente, do mecanico e do almoxarife"

# 2. Estoque inicial.
D0=$(disponivel) || falhar 2 "GET /pecas/$PECA_ID_SEED: $(resumo) (o SeedPecas rodou?)"
passo 2 "peca do seed com qtdDisponivel D0 = $D0"

# 3. Abertura com repasse do JWT.
OS_ID=$(abrir_os "demo da Saga com o Execucao (F5)") || falhar 3 "POST /ordem-servicos: $(resumo)"
passo 3 "POST /ordem-servicos -> 201 RECEBIDA (osId $OS_ID)"

# 4. A OS vai a EM_DIAGNOSTICO com o Execucao real (DoD da F5).
esperar 15 2 os_tem "$OS_ID" situacao EM_DIAGNOSTICO \
  || falhar 4 "OS $OS_ID continua $(campo_os "$OS_ID" situacao || true) (confira o consumidor do Execucao, o APP_MESSAGING_CONSUMIDOR_FILAS do ConfigMap, a DLQ mecanica-execucao-comandos-dlq e o log outbox_publicacao_falhou)"
execucao_tem "$OS_ID" EM_DIAGNOSTICO || falhar 4 "GET /execucoes/$OS_ID: $(resumo)"
esperar 5 2 na_fila "$OS_ID" || falhar 4 "OS $OS_ID fora de GET /execucoes/fila: $(resumo)"
passo 4 "OS EM_DIAGNOSTICO em ate 30 s; a ordem esta no Execucao e na fila"

# 5. Prestacao: o Execucao consulta o catalogo do OS repassando o JWT do mecanico (F5-o).
status=$(api "$TOKEN_MECANICO" POST "/execucoes/$OS_ID/prestacoes" \
  "{\"servicoId\":\"$SERVICO_ID_SEED\",\"precoMaoDeObra\":$PRECO_MAO_DE_OBRA}")
[[ "$status" == 201 && "$(jq -r .nomeServico "$TMP/resp.json")" == "Troca de oleo" ]] \
  || falhar 5 "POST /prestacoes: HTTP $status: $(resumo) (502 INTEGRACAO_OS ou 503 OS_INDISPONIVEL: confira o APP_OS_BASE_URL)"
PRESTACAO_ID=$(jq -r .id "$TMP/resp.json")
passo 5 "POST /prestacoes -> 201 com nomeServico \"Troca de oleo\" (prestacao $PRESTACAO_ID)"

# 6. Alocacao de peca (nao mexe no estoque: a reserva vem da Saga).
status=$(api "$TOKEN_ALMOXARIFE" POST "/execucoes/$OS_ID/prestacoes/$PRESTACAO_ID/pecas" \
  "{\"pecaId\":\"$PECA_ID_SEED\",\"quantidade\":$QUANTIDADE}")
[[ "$status" == 201 ]] || falhar 6 "POST /pecas da prestacao: HTTP $status: $(resumo)"
disponivel_e "$D0" || falhar 6 "a alocacao nao deveria mexer no estoque: qtdDisponivel $(disponivel) (esperado $D0)"
passo 6 "peca alocada (quantidade $QUANTIDADE) -> 201, estoque ainda em $D0"

# 7. Conclusao do diagnostico: o Execucao emite DiagnosticoConcluido pela outbox.
status=$(api "$TOKEN_MECANICO" PATCH "/execucoes/$OS_ID/diagnostico/concluir")
[[ "$status" == 200 && "$(jq -r .status "$TMP/resp.json")" == DIAGNOSTICO_CONCLUIDO ]] \
  || falhar 7 "PATCH /diagnostico/concluir: HTTP $status: $(resumo)"
passo 7 "PATCH /diagnostico/concluir -> 200 DIAGNOSTICO_CONCLUIDO"

# 8. A Saga reserva as pecas (ReservarPecas real) e o Billing real gera o orcamento (F6-l).
esperar 15 2 os_tem "$OS_ID" situacao AGUARDANDO_APROVACAO \
  || falhar 8 "OS $OS_ID continua $(campo_os "$OS_ID" situacao || true) (esperado AGUARDANDO_APROVACAO; confira a ReservaPecasRecusada no log do Execucao e o consumidor do Billing)"
esperar 5 2 disponivel_e "$((D0 - QUANTIDADE))" \
  || falhar 8 "qtdDisponivel $(disponivel || true), esperado $((D0 - QUANTIDADE)) (reserva real)"
esperar 10 2 orcamento_tem "$OS_ID" GERADO \
  || falhar 8 "orcamento da OS $OS_ID: '$(status_orcamento "$OS_ID" || true)', esperado GERADO (confira a billing-comandos e a DLQ mecanica-billing-comandos-dlq)"
jq -e --argjson total "$VALOR_TOTAL_ESPERADO" '.valorTotal == $total' "$TMP/resp.json" > /dev/null \
  || falhar 8 "orcamento com valorTotal $(jq -r .valorTotal "$TMP/resp.json"), esperado $VALOR_TOTAL_ESPERADO"
passo 8 "OS AGUARDANDO_APROVACAO, qtdDisponivel = $((D0 - QUANTIDADE)), orcamento GERADO com valorTotal $VALOR_TOTAL_ESPERADO"

# 9. Cancelamento com reserva: a Saga compensa e o estoque volta (compensacao real).
status=$(api "$TOKEN_ATENDENTE" PATCH "/ordem-servicos/$OS_ID/cancelar" '{"motivo":"demo da Saga com o Execucao"}')
[[ "$status" == 200 && "$(jq -r .situacao "$TMP/resp.json")" == CANCELADA ]] \
  || falhar 9 "PATCH /cancelar: HTTP $status: $(resumo)"
esperar 15 2 os_tem "$OS_ID" sagaStatus COMPENSADA \
  || falhar 9 "Saga esperada COMPENSADA, obtido '$(campo_os "$OS_ID" sagaStatus || true)'"
esperar 5 2 disponivel_e "$D0" || falhar 9 "qtdDisponivel $(disponivel || true), esperado $D0 (compensacao real)"
esperar 10 2 orcamento_tem "$OS_ID" CANCELADO \
  || falhar 9 "orcamento da OS $OS_ID: '$(status_orcamento "$OS_ID" || true)', esperado CANCELADO (CancelarOrcamento da F4)"
esperar 10 2 execucao_tem "$OS_ID" CANCELADA || falhar 9 "ordem $OS_ID no Execucao: '$(status_execucao "$OS_ID" || true)', esperado CANCELADA"
if na_fila "$OS_ID"; then falhar 9 "a ordem cancelada continua em GET /execucoes/fila"; fi
passo 9 "OS CANCELADA, Saga COMPENSADA, qtdDisponivel de volta a $D0, orcamento CANCELADO, ordem CANCELADA e fora da fila"

# 10. Cancelamento sem reserva: so o OrdemServicoCancelada (assinatura filtrada) chega ao Execucao.
OS_ID2=$(abrir_os "demo da Saga: cancelamento sem reserva (F5-b)") || falhar 10 "POST /ordem-servicos: $(resumo)"
esperar 15 2 os_tem "$OS_ID2" situacao EM_DIAGNOSTICO || falhar 10 "OS $OS_ID2 nao chegou a EM_DIAGNOSTICO"
status=$(api "$TOKEN_ATENDENTE" PATCH "/ordem-servicos/$OS_ID2/cancelar" '{"motivo":"demo: sem reserva"}')
[[ "$status" == 200 && "$(jq -r .situacao "$TMP/resp.json")" == CANCELADA ]] \
  || falhar 10 "PATCH /cancelar da OS $OS_ID2: HTTP $status: $(resumo)"
esperar 15 2 execucao_tem "$OS_ID2" CANCELADA \
  || falhar 10 "ordem $OS_ID2 no Execucao: '$(status_execucao "$OS_ID2" || true)', esperado CANCELADA (confira a FilterPolicy da assinatura e a DLQ mecanica-execucao-os-eventos-dlq)"
passo 10 "OS $OS_ID2 cancelada sem reserva -> ordem CANCELADA no Execucao (OrdemServicoCancelada)"

# 11. Nada ficou em DLQ e o Execucao nao registrou falha de mensagem.
for dlq in mecanica-execucao-comandos-dlq mecanica-execucao-os-eventos-dlq mecanica-os-saga-respostas-dlq; do
  url=$(aws sqs get-queue-url --queue-name "$dlq" --query QueueUrl --output text) || falhar 11 "fila $dlq nao existe"
  total=$(aws sqs get-queue-attributes --queue-url "$url" --attribute-names ApproximateNumberOfMessages \
    --query Attributes.ApproximateNumberOfMessages --output text)
  [[ "$total" == 0 ]] || falhar 11 "$dlq com $total mensagem(ns)"
done
kubectl logs -l app=mecanica-execucao -n "$NAMESPACE" --since=10m --tail=-1 > "$TMP/execucao.log" 2> /dev/null \
  || falhar 11 "kubectl logs do Execucao (confira o kubeconfig: aws eks update-kubeconfig --name <cluster>)"
if grep -q mensagem_falhou "$TMP/execucao.log"; then
  grep mensagem_falhou "$TMP/execucao.log" | head -3 | cut -c1-240
  falhar 11 "mensagem_falhou no log do Execucao"
fi
passo 11 "3 DLQs com 0 mensagens e nenhum mensagem_falhou no log do Execucao"

echo
echo "Demo da Saga com o Execucao: tudo OK (osId $OS_ID e $OS_ID2)."
