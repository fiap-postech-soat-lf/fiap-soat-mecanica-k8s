#!/usr/bin/env bash
# Confere o ambiente local: Postgres dos 3 servicos SQL, as 6 tabelas DynamoDB do Execucao (com GSIs e TTL),
# filas (com DLQ e redrive), topicos e assinaturas raw da tabela 3.4, e testes ponta a ponta SNS -> SQS:
# a entrega sem o embrulho do SNS e o filtro da assinatura do Execucao (F5-b).
#
# Uso: docker compose -f local/docker-compose.yml up -d && local/verificar.sh
# Pare o OS e o Execucao locais antes: eles consomem a mecanica-os-saga-respostas e a
# mecanica-execucao-os-eventos usadas nos testes ponta a ponta.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE="$DIR/docker-compose.yml"
CONTA=000000000000
REGIAO=us-east-1
FILAS=(mecanica-execucao-comandos mecanica-execucao-os-eventos mecanica-billing-comandos mecanica-os-saga-respostas mecanica-identity-notificacoes)
TOPICOS=(mecanica-execucao-eventos mecanica-billing-eventos mecanica-os-eventos)
# topico:fila[:type]; com o terceiro campo, a assinatura tem FilterPolicy {type: [<type>]}
ASSINATURAS=(
  mecanica-execucao-eventos:mecanica-os-saga-respostas
  mecanica-billing-eventos:mecanica-os-saga-respostas
  mecanica-os-eventos:mecanica-identity-notificacoes
  mecanica-os-eventos:mecanica-execucao-os-eventos:OrdemServicoCancelada
)
# nome:chave (hash[,range]) e GSIs/TTL esperados, iguais ao infra/dynamodb.tf do -execucao (RFC-F4-02)
TABELAS=(
  "execucao-ordens:osId" "execucao-pecas:pecaId" "execucao-reservas:osId,pecaId"
  "execucao-outbox:id" "execucao-idempotencia:messageId" "execucao-tempos:servicoId"
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

echo "== DynamoDB"
for tabela in "${TABELAS[@]}"; do
  nome=${tabela%%:*}
  esperado=${tabela#*:}
  if ! descricao=$(aws_local dynamodb describe-table --table-name "$nome" 2> /dev/null | jq .Table); then
    falha "$nome nao existe"; continue
  fi
  chaves=$(jq -r '[.KeySchema[].AttributeName] | join(",")' <<< "$descricao")
  billing=$(jq -r '.BillingModeSummary.BillingMode // "PROVISIONED"' <<< "$descricao")
  if [[ "$chaves" == "$esperado" && "$billing" == PAY_PER_REQUEST ]]; then
    ok "$nome (chave $chaves, on-demand)"
  else
    falha "$nome: chave='$chaves' (esperada $esperado) billing='$billing'"
  fi
done
indice() { # indice <tabela> <gsi> <hash,range>
  obtido=$(aws_local dynamodb describe-table --table-name "$1" 2> /dev/null \
    | jq -r --arg gsi "$2" '.Table.GlobalSecondaryIndexes[]? | select(.IndexName == $gsi)
      | "\([.KeySchema[].AttributeName] | join(",")) \(.Projection.ProjectionType)"' || true)
  if [[ "$obtido" == "$3 ALL" ]]; then ok "GSI $1.$2 ($3, projecao ALL)"; else falha "GSI $1.$2: '$obtido'"; fi
}
indice execucao-ordens fila fila,filaOrdem
indice execucao-outbox pendentes pendente,criadoEm
for tabela in execucao-outbox execucao-idempotencia; do
  ttl=$(aws_local dynamodb describe-time-to-live --table-name "$tabela" 2> /dev/null \
    | jq -r '.TimeToLiveDescription | "\(.TimeToLiveStatus) \(.AttributeName)"' || true)
  if [[ "$ttl" == "ENABLED expiraEm" ]]; then ok "TTL $tabela (expiraEm)"; else falha "TTL $tabela: '$ttl'"; fi
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
  resto=${assinatura#*:}
  fila=${resto%%:*}
  tipo=${resto#"$fila"}
  tipo=${tipo#:}
  arn=$(aws_local sns list-subscriptions-by-topic --topic-arn "arn:aws:sns:$REGIAO:$CONTA:$topico" 2> /dev/null \
    | jq -r --arg fila "arn:aws:sqs:$REGIAO:$CONTA:$fila" '.Subscriptions[] | select(.Endpoint == $fila) | .SubscriptionArn' || true)
  if [[ -z "$arn" ]]; then
    falha "$topico -> $fila nao existe"; continue
  fi
  atributos=$(aws_local sns get-subscription-attributes --subscription-arn "$arn" | jq .Attributes)
  raw=$(jq -r .RawMessageDelivery <<< "$atributos")
  filtro=$(jq -c '.FilterPolicy // "" | if . == "" then "" else fromjson end' <<< "$atributos")
  if [[ "$raw" != true ]]; then
    falha "$topico -> $fila sem RawMessageDelivery"
  elif [[ -n "$tipo" && "$filtro" != "{\"type\":[\"$tipo\"]}" ]]; then
    falha "$topico -> $fila: FilterPolicy esperada {type:[$tipo]}, obtida '$filtro'"
  elif [[ -z "$tipo" && "$filtro" != '""' ]]; then
    falha "$topico -> $fila nao deveria ter FilterPolicy: '$filtro'"
  elif [[ -n "$tipo" ]]; then
    ok "$topico -> $fila (raw, filtrada por type=$tipo)"
  else
    ok "$topico -> $fila (raw)"
  fi
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

echo "== Ponta a ponta: filtro da assinatura mecanica-os-eventos -> mecanica-execucao-os-eventos (F5-b)"
topico_os="arn:aws:sns:$REGIAO:$CONTA:mecanica-os-eventos"
publicar_os() { # publicar_os <type> <messageId>
  envelope=$(jq -nc --arg id "$2" --arg tipo "$1" --arg agora "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{messageId: $id, type: $tipo, version: 1, correlationId: "verificar-local", occurredAt: $agora, payload: {osId: $id}}')
  aws_local sns publish --topic-arn "$topico_os" --message "$envelope" \
    --message-attributes "{\"type\":{\"DataType\":\"String\",\"StringValue\":\"$1\"}}" > /dev/null
}
# esvaziar_ids <fila> <ids...>: apaga da fila as mensagens do teste (best effort) e imprime os ids achados.
esvaziar_ids() {
  local fila="$1" url achados="" mensagens msg id
  shift
  url=$(aws_local sqs get-queue-url --queue-name "$fila" | jq -r .QueueUrl)
  for _ in 1 2 3; do
    mensagens=$(aws_local sqs receive-message --queue-url "$url" --max-number-of-messages 10 --wait-time-seconds 1 || true)
    [[ -n "$mensagens" ]] || continue
    while IFS= read -r msg; do
      [[ -n "$msg" ]] || continue
      id=$(jq -r '.Body | fromjson? | .messageId // empty' <<< "$msg")
      for alvo in "$@"; do
        if [[ "$id" == "$alvo" ]]; then
          achados+="$id "
          aws_local sqs delete-message --queue-url "$url" --receipt-handle "$(jq -r .ReceiptHandle <<< "$msg")"
        fi
      done
    done < <(jq -c '.Messages[]?' <<< "$mensagens")
  done
  echo "$achados"
}
id_situacao=$(cat /proc/sys/kernel/random/uuid)
id_cancelada=$(cat /proc/sys/kernel/random/uuid)
publicar_os SituacaoOrdemServicoAlterada "$id_situacao"
publicar_os OrdemServicoCancelada "$id_cancelada"
chegaram=$(esvaziar_ids mecanica-execucao-os-eventos "$id_situacao" "$id_cancelada")
esvaziar_ids mecanica-identity-notificacoes "$id_situacao" "$id_cancelada" > /dev/null
if [[ "$chegaram" == *"$id_cancelada"* ]]; then
  ok "OrdemServicoCancelada chegou na mecanica-execucao-os-eventos"
else
  falha "OrdemServicoCancelada nao chegou na mecanica-execucao-os-eventos (o Execucao local esta consumindo a fila?)"
fi
if [[ "$chegaram" == *"$id_situacao"* ]]; then
  falha "SituacaoOrdemServicoAlterada chegou na mecanica-execucao-os-eventos: o filtro nao funcionou"
else
  ok "SituacaoOrdemServicoAlterada nao chegou na mecanica-execucao-os-eventos (filtro por type)"
fi

echo
if [[ $falhas -eq 0 ]]; then
  echo "OK: ambiente local pronto"
else
  echo "FALHA: $falhas verificacao(oes) falharam" >&2
  exit 1
fi
