#!/usr/bin/env bash
# Cria a mensageria da Fase 4 no LocalStack com os mesmos nomes do Terraform (tabela 3.4 do plano da F1).
# Roda dentro do container (hook ready.d do LocalStack). Idempotente: create-queue, create-topic e
# subscribe devolvem o recurso existente quando os atributos sao iguais.
set -euo pipefail

REGIAO=us-east-1
CONTA=000000000000
FILAS=(mecanica-execucao-comandos mecanica-execucao-os-eventos mecanica-billing-comandos mecanica-os-saga-respostas mecanica-identity-notificacoes)
TOPICOS=(mecanica-execucao-eventos mecanica-billing-eventos mecanica-os-eventos)
# topico:fila[:type] (entrega raw). Com o terceiro campo, a assinatura so recebe mensagens cujo atributo
# type seja esse (FilterPolicy), como a do Execucao em F5-b.
ASSINATURAS=(
  mecanica-execucao-eventos:mecanica-os-saga-respostas
  mecanica-billing-eventos:mecanica-os-saga-respostas
  mecanica-os-eventos:mecanica-identity-notificacoes
  mecanica-os-eventos:mecanica-execucao-os-eventos:OrdemServicoCancelada
)

arn_fila() { echo "arn:aws:sqs:$REGIAO:$CONTA:$1"; }
arn_topico() { echo "arn:aws:sns:$REGIAO:$CONTA:$1"; }
url_fila() { awslocal sqs get-queue-url --queue-name "$1" --query QueueUrl --output text; }
# A imagem do LocalStack tem python3, mas nao jq: o JSON dos atributos e montado com ele.
json() { python3 -c "import json, sys; print(json.dumps($1))" "${@:2}"; }

for fila in "${FILAS[@]}"; do
  awslocal sqs create-queue --queue-name "$fila-dlq" \
    --attributes MessageRetentionPeriod=345600 > /dev/null
  atributos=$(json '{"VisibilityTimeout": "30", "MessageRetentionPeriod": "345600",
    "RedrivePolicy": json.dumps({"deadLetterTargetArn": sys.argv[1], "maxReceiveCount": "5"})}' \
    "$(arn_fila "$fila-dlq")")
  awslocal sqs create-queue --queue-name "$fila" --attributes "$atributos" > /dev/null
done

for topico in "${TOPICOS[@]}"; do
  awslocal sns create-topic --name "$topico" > /dev/null
done

# Policy de cada fila assinada: permite o sns:SendMessage dos topicos que a assinam (espelha o Terraform;
# o LocalStack nao exige).
declare -A ORIGENS=()
for assinatura in "${ASSINATURAS[@]}"; do
  resto=${assinatura#*:}
  fila=${resto%%:*}
  ORIGENS[$fila]+="$(arn_topico "${assinatura%%:*}") "
done
for fila in "${!ORIGENS[@]}"; do
  read -r -a topicos <<< "${ORIGENS[$fila]}"
  atributos=$(json '{"Policy": json.dumps({
      "Version": "2012-10-17",
      "Statement": [{
        "Sid": "PermitirTopicosSns",
        "Effect": "Allow",
        "Principal": {"Service": "sns.amazonaws.com"},
        "Action": "sqs:SendMessage",
        "Resource": sys.argv[1],
        "Condition": {"ArnEquals": {"aws:SourceArn": sys.argv[2:]}}
      }]})}' "$(arn_fila "$fila")" "${topicos[@]}")
  awslocal sqs set-queue-attributes --queue-url "$(url_fila "$fila")" --attributes "$atributos"
done

for assinatura in "${ASSINATURAS[@]}"; do
  resto=${assinatura#*:}
  fila=${resto%%:*}
  tipo=${resto#"$fila"}
  tipo=${tipo#:}
  # O FilterPolicy e uma string JSON dentro do JSON dos atributos.
  atributos=$(json '{"RawMessageDelivery": "true",
    **({"FilterPolicy": json.dumps({"type": [sys.argv[1]]})} if sys.argv[1] else {})}' "$tipo")
  awslocal sns subscribe --topic-arn "$(arn_topico "${assinatura%%:*}")" --protocol sqs \
    --notification-endpoint "$(arn_fila "$fila")" --attributes "$atributos" > /dev/null
done

echo "mensageria criada: ${#FILAS[@]} filas (+ DLQs), ${#TOPICOS[@]} topicos, ${#ASSINATURAS[@]} assinaturas raw"
