#!/usr/bin/env bash
# Confere o ambiente local: Postgres dos 3 servicos SQL, filas (com DLQ e redrive), topicos e assinaturas
# raw da tabela 3.4, e um teste ponta a ponta SNS -> SQS que prova a entrega sem o embrulho do SNS.
#
# Uso: docker compose -f local/docker-compose.yml up -d && local/verificar.sh
# Pare o OS local antes: ele consome a mecanica-os-saga-respostas usada no teste ponta a ponta.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE="$DIR/docker-compose.yml"
CONTA=000000000000
REGIAO=us-east-1
FILAS=(mecanica-execucao-comandos mecanica-billing-comandos mecanica-os-saga-respostas mecanica-identity-notificacoes)
TOPICOS=(mecanica-execucao-eventos mecanica-billing-eventos mecanica-os-eventos)
ASSINATURAS=(
  mecanica-execucao-eventos:mecanica-os-saga-respostas
  mecanica-billing-eventos:mecanica-os-saga-respostas
  mecanica-os-eventos:mecanica-identity-notificacoes
)
falhas=0

aws_local() { docker compose -f "$COMPOSE" exec -T localstack awslocal --output json "$@"; }
ok() { echo "   OK     $*"; }
falha() { echo "   FALHA  $*"; falhas=$((falhas + 1)); }

echo "== Postgres"
for svc in identity os billing; do
  if docker compose -f "$COMPOSE" exec -T "postgres-$svc" pg_isready -U postgres -d "$svc" > /dev/null 2>&1; then
    ok "postgres-$svc (banco $svc)"
  else
    falha "postgres-$svc nao responde"
  fi
done

echo "== Filas"
for fila in "${FILAS[@]}"; do
  if ! url=$(aws_local sqs get-queue-url --queue-name "$fila" 2> /dev/null | jq -r .QueueUrl); then
    falha "$fila nao existe"; continue
  fi
  atributos=$(aws_local sqs get-queue-attributes --queue-url "$url" --attribute-names All | jq .Attributes)
  dlq=$(jq -r '.RedrivePolicy // "{}" | fromjson | "\(.deadLetterTargetArn) \(.maxReceiveCount)"' <<< "$atributos")
  visibilidade=$(jq -r .VisibilityTimeout <<< "$atributos")
  if [[ "$dlq" == "arn:aws:sqs:$REGIAO:$CONTA:$fila-dlq 5" && "$visibilidade" == 30 ]] \
    && aws_local sqs get-queue-url --queue-name "$fila-dlq" > /dev/null 2>&1; then
    ok "$fila (+ dlq, maxReceiveCount=5, visibility 30 s)"
  else
    falha "$fila: redrive='$dlq' visibility='$visibilidade'"
  fi
done

echo "== Topicos e assinaturas"
topicos=$(aws_local sns list-topics | jq -r '.Topics[].TopicArn')
for topico in "${TOPICOS[@]}"; do
  if grep -qx "arn:aws:sns:$REGIAO:$CONTA:$topico" <<< "$topicos"; then ok "$topico"; else falha "$topico nao existe"; fi
done
for assinatura in "${ASSINATURAS[@]}"; do
  topico=${assinatura%%:*}
  fila=${assinatura#*:}
  arn=$(aws_local sns list-subscriptions-by-topic --topic-arn "arn:aws:sns:$REGIAO:$CONTA:$topico" 2> /dev/null \
    | jq -r --arg fila "arn:aws:sqs:$REGIAO:$CONTA:$fila" '.Subscriptions[] | select(.Endpoint == $fila) | .SubscriptionArn' || true)
  if [[ -z "$arn" ]]; then
    falha "$topico -> $fila nao existe"; continue
  fi
  raw=$(aws_local sns get-subscription-attributes --subscription-arn "$arn" | jq -r .Attributes.RawMessageDelivery)
  if [[ "$raw" == true ]]; then ok "$topico -> $fila (raw)"; else falha "$topico -> $fila sem RawMessageDelivery"; fi
done

echo "== Ponta a ponta: mecanica-execucao-eventos -> mecanica-os-saga-respostas"
message_id=$(cat /proc/sys/kernel/random/uuid)
envelope=$(jq -nc --arg id "$message_id" --arg agora "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  '{messageId: $id, type: "DiagnosticoAberto", version: 1, correlationId: "verificar-local",
    occurredAt: $agora, payload: {osId: $id, abertoEm: $agora}}')
aws_local sns publish --topic-arn "arn:aws:sns:$REGIAO:$CONTA:mecanica-execucao-eventos" --message "$envelope" \
  --message-attributes '{"type":{"DataType":"String","StringValue":"DiagnosticoAberto"}}' > /dev/null
url=$(aws_local sqs get-queue-url --queue-name mecanica-os-saga-respostas | jq -r .QueueUrl)
recebida=""
for _ in 1 2 3 4 5; do
  mensagens=$(aws_local sqs receive-message --queue-url "$url" --max-number-of-messages 10 --wait-time-seconds 2 \
    --message-attribute-names All)
  [[ -n "$mensagens" ]] || continue
  recebida=$(jq -c --arg id "$message_id" '.Messages[]? | select((.Body | fromjson? | .messageId) == $id)' <<< "$mensagens")
  if [[ -n "$recebida" ]]; then
    aws_local sqs delete-message --queue-url "$url" --receipt-handle "$(jq -r .ReceiptHandle <<< "$recebida")"
    break
  fi
done
if [[ -z "$recebida" ]]; then
  falha "envelope nao chegou na fila (o OS local esta consumindo a fila?)"
elif [[ "$(jq -S .Body <<< "$recebida" | jq -r . | jq -cS .)" == "$(jq -cS . <<< "$envelope")" ]] \
  && [[ "$(jq -r '.MessageAttributes.type.StringValue' <<< "$recebida")" == DiagnosticoAberto ]]; then
  ok "chegou identico ao envelope publicado (sem embrulho SNS), com o atributo type"
else
  falha "corpo recebido difere do envelope: $(jq -r .Body <<< "$recebida")"
fi

echo
if [[ $falhas -eq 0 ]]; then
  echo "OK: ambiente local pronto"
else
  echo "FALHA: $falhas verificacao(oes) falharam" >&2
  exit 1
fi
