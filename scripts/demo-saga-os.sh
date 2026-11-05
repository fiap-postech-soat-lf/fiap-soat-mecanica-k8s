#!/usr/bin/env bash
# Demo da Saga do OS no EKS (CP2, F4-n). ESCREVE DADOS: abre uma OS de verdade no OS Service,
# publica uma mensagem no topico execucao-eventos e cancela a OS. Nao rodar contra um ambiente
# que nao seja descartavel. O smoke-borda.sh, esse sim, so le.
#
# Passos:
#   1. login do atendente (seed) e POST /ordem-servicos com o veiculo do seed -> 201 RECEBIDA
#   2. o comando AbrirDiagnostico dessa OS esta na fila mecanica-execucao-comandos
#      (o Execucao ainda nao consome, F4-k; a leitura usa visibility-timeout 0)
#   3. simula o Execucao: publica DiagnosticoAberto no topico execucao-eventos
#   4. a OS vai para EM_DIAGNOSTICO (ate 30 s) e o historico tem 2 linhas
#   5. PATCH /cancelar -> 200 CANCELADA, e a Saga fica COMPENSADA (nao havia reserva)
#   6. o log do Identity tem 3 notificacao_os_enviada dessa OS (RECEBIDA, EM_DIAGNOSTICO, cancelamento)
#
# Uso: scripts/demo-saga-os.sh
# Le do SSM /mecanica/auth/api-url, /mecanica/execucao/* e usa kubectl (kubeconfig do cluster:
#   aws eks update-kubeconfig --name <cluster>) para o log do Identity.
# Saida: 0 se tudo passar, 1 se algum passo falhar.
# Variaveis: AWS_REGION (padrao us-east-1), NAMESPACE (padrao mecanica)
set -euo pipefail

export AWS_DEFAULT_REGION="${AWS_REGION:-us-east-1}"
NAMESPACE="${NAMESPACE:-mecanica}"

# Dados do seed do Identity (V5__seed.sql em fiap-soat-mecanica-identity).
EMAIL_ATENDENTE_SEED="atendente@mecanica.test"
SENHA_SEED="Senha@123"
VEICULO_ID_SEED="44444444-4444-4444-4444-444444444444"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
umask 077

ssm() { aws ssm get-parameter --name "$1" --query Parameter.Value --output text; }
uuid() { cat /proc/sys/kernel/random/uuid 2> /dev/null || uuidgen | tr '[:upper:]' '[:lower:]'; }
passo() { printf 'PASS  %-3s %s\n' "$1" "$2"; }
falhar() {
  printf 'FAIL  %-3s %s\n' "$1" "$2" >&2
  exit 1
}

# api <metodo> <caminho> [corpo]: devolve o corpo em $TMP/resp.json e imprime o status HTTP.
api() {
  local metodo="$1" caminho="$2" corpo="${3:-}"
  local args=(--silent --show-error --max-time 20 --output "$TMP/resp.json" --write-out '%{http_code}'
    -X "$metodo" -H 'Content-Type: application/json')
  [[ -n "${TOKEN:-}" ]] && args+=(-H "Authorization: Bearer $TOKEN")
  [[ -n "$corpo" ]] && args+=(--data "$corpo")
  curl "${args[@]}" "$API$caminho" || true
}

API=$(ssm /mecanica/auth/api-url)
API="${API%/}"
FILA_COMANDOS=$(ssm /mecanica/execucao/execucao-comandos-queue-url)
TOPICO_EVENTOS=$(ssm /mecanica/execucao/execucao-eventos-topic-arn)
echo "API: $API"
echo

# 1. Abertura com repasse do JWT (F3-a, F4-b).
status=$(api POST /auth/login "{\"email\":\"$EMAIL_ATENDENTE_SEED\",\"senha\":\"$SENHA_SEED\"}")
[[ "$status" == 200 ]] || falhar 1 "login do atendente: HTTP $status"
TOKEN=$(jq -r '.accessToken // empty' "$TMP/resp.json")
[[ -n "$TOKEN" ]] || falhar 1 "login sem accessToken"

status=$(api POST /ordem-servicos "{\"veiculoId\":\"$VEICULO_ID_SEED\",\"observacao\":\"demo da Saga (F4)\"}")
[[ "$status" == 201 ]] || falhar 1 "POST /ordem-servicos: HTTP $status: $(head -c 300 "$TMP/resp.json")"
OS_ID=$(jq -r .id "$TMP/resp.json")
[[ "$(jq -r .situacao "$TMP/resp.json")" == RECEBIDA ]] || falhar 1 "OS $OS_ID nao nasceu RECEBIDA"
passo 1 "POST /ordem-servicos -> 201 RECEBIDA (osId $OS_ID)"

# 2. O comando AbrirDiagnostico chegou na fila do Execucao (o outbox publica em ~1 s).
COMANDO=""
for _ in $(seq 1 10); do
  aws sqs receive-message --queue-url "$FILA_COMANDOS" --visibility-timeout 0 \
    --max-number-of-messages 10 --wait-time-seconds 3 --output json > "$TMP/fila.json"
  COMANDO=$(jq -c --arg os "$OS_ID" \
    '[.Messages[]?.Body | fromjson | select(.type == "AbrirDiagnostico" and .osId == $os)] | first // empty' \
    "$TMP/fila.json")
  [[ -n "$COMANDO" ]] && break
done
[[ -n "$COMANDO" ]] || falhar 2 "AbrirDiagnostico da OS $OS_ID nao apareceu em mecanica-execucao-comandos"
passo 2 "AbrirDiagnostico na fila mecanica-execucao-comandos"

# 3. Simula o Execucao: DiagnosticoAberto com sagaId e osId do comando e causationId = messageId.
RESPOSTA=$(jq -c --arg id "$(uuid)" --arg agora "$(date -u +%Y-%m-%dT%H:%M:%S.000Z)" '{
    messageId: $id, type: "DiagnosticoAberto", version: 1,
    sagaId: .sagaId, osId: .osId, correlationId: .correlationId, causationId: .messageId,
    occurredAt: $agora, payload: {osId: .osId, abertoEm: $agora}
  }' <<< "$COMANDO")
aws sns publish --topic-arn "$TOPICO_EVENTOS" --message "$RESPOSTA" --output text \
  --query MessageId > /dev/null || falhar 3 "falha ao publicar em execucao-eventos"
passo 3 "DiagnosticoAberto publicado em mecanica-execucao-eventos"

# 4. A resposta volta pelo SNS -> SQS raw e o OS passa para EM_DIAGNOSTICO.
SITUACAO=""
for _ in $(seq 1 15); do
  status=$(api GET "/ordem-servicos/$OS_ID")
  SITUACAO=$(jq -r '.situacao // empty' "$TMP/resp.json" 2> /dev/null || true)
  [[ "$status" == 200 && "$SITUACAO" == EM_DIAGNOSTICO ]] && break
  sleep 2
done
[[ "$SITUACAO" == EM_DIAGNOSTICO ]] \
  || falhar 4 "OS $OS_ID continua $SITUACAO (confira a assinatura execucao-eventos -> os-saga-respostas, a DLQ e o log mensagem_falhou do OS)"
status=$(api GET "/ordem-servicos/$OS_ID/historico")
[[ "$status" == 200 && "$(jq length "$TMP/resp.json")" == 2 ]] \
  || falhar 4 "historico esperado com 2 linhas: HTTP $status: $(head -c 300 "$TMP/resp.json")"
passo 4 "OS EM_DIAGNOSTICO, historico com 2 linhas"

# 5. Cancelamento: a OS vira CANCELADA na hora e, sem reserva, a Saga vai direto a COMPENSADA.
status=$(api PATCH "/ordem-servicos/$OS_ID/cancelar" '{"motivo":"demo da Saga"}')
[[ "$status" == 200 && "$(jq -r .situacao "$TMP/resp.json")" == CANCELADA ]] \
  || falhar 5 "PATCH /cancelar: HTTP $status: $(head -c 300 "$TMP/resp.json")"
status=$(api GET "/ordem-servicos/$OS_ID")
[[ "$status" == 200 && "$(jq -r .sagaStatus "$TMP/resp.json")" == COMPENSADA ]] \
  || falhar 5 "Saga esperada COMPENSADA, obtido $(jq -r .sagaStatus "$TMP/resp.json")"
passo 5 "PATCH /cancelar -> 200 CANCELADA, Saga COMPENSADA"

# 6. O Identity notificou o cliente pela assinatura do OS (F4-a): 3 eventos dessa OS.
NOTIFICACOES=0
for _ in $(seq 1 10); do
  kubectl logs -l app=mecanica-identity -n "$NAMESPACE" --since=5m --tail=-1 > "$TMP/identity.log" 2> /dev/null || true
  NOTIFICACOES=$(grep -F "$OS_ID" "$TMP/identity.log" | grep -c notificacao_os_enviada || true)
  [[ "$NOTIFICACOES" -ge 3 ]] && break
  sleep 3
done
[[ "$NOTIFICACOES" -ge 3 ]] \
  || falhar 6 "esperadas 3 notificacao_os_enviada da OS $OS_ID, achei $NOTIFICACOES (confira o kubeconfig e a fila identity-notificacoes)"
grep -F "$OS_ID" "$TMP/identity.log" | grep notificacao_os_enviada | cut -c1-240
passo 6 "$NOTIFICACOES notificacao_os_enviada no log do Identity"

echo
echo "Demo da Saga: tudo OK (osId $OS_ID)."
