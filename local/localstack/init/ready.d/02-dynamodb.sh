#!/usr/bin/env bash
# Cria as 6 tabelas DynamoDB do Execucao no LocalStack com os mesmos nomes, chaves, GSIs e TTL do
# infra/dynamodb.tf do -execucao (RFC-F4-02). Roda dentro do container (hook ready.d do LocalStack,
# depois do 01-mensageria.sh). Idempotente: pula a tabela que ja existe.
set -euo pipefail

# criar_tabela <nome> <atributos> <chaves> [<gsi-json>]
#   atributos: lista "Nome:Tipo" separada por espaco (so as que sao chave da tabela ou de GSI)
#   chaves:    "HASH" ou "HASH,RANGE" (nomes de atributo)
#   gsi-json:  argumento --global-secondary-indexes (JSON), opcional
criar_tabela() {
  local nome="$1" atributos="$2" chaves="$3" gsi="${4:-}"
  if awslocal dynamodb describe-table --table-name "$nome" > /dev/null 2>&1; then
    echo "tabela $nome ja existe"
    return
  fi
  local definicoes=() par
  for par in $atributos; do
    definicoes+=("AttributeName=${par%%:*},AttributeType=${par##*:}")
  done
  local esquema=("AttributeName=${chaves%%,*},KeyType=HASH")
  [[ "$chaves" == *,* ]] && esquema+=("AttributeName=${chaves##*,},KeyType=RANGE")
  local extra=()
  [[ -n "$gsi" ]] && extra=(--global-secondary-indexes "$gsi")
  awslocal dynamodb create-table --table-name "$nome" --billing-mode PAY_PER_REQUEST \
    --attribute-definitions "${definicoes[@]}" --key-schema "${esquema[@]}" "${extra[@]}" > /dev/null
}

ativar_ttl() {
  awslocal dynamodb update-time-to-live --table-name "$1" \
    --time-to-live-specification "Enabled=true,AttributeName=$2" > /dev/null
}

gsi() { # gsi <nome> <hash> <range>
  printf '[{"IndexName":"%s","KeySchema":[{"AttributeName":"%s","KeyType":"HASH"},{"AttributeName":"%s","KeyType":"RANGE"}],"Projection":{"ProjectionType":"ALL"}}]' "$1" "$2" "$3"
}

# GSI esparso fila (F5-j): so as ordens ativas tem fila e filaOrdem.
criar_tabela execucao-ordens "osId:S fila:S filaOrdem:S" osId "$(gsi fila fila filaOrdem)"
criar_tabela execucao-pecas "pecaId:S" pecaId
criar_tabela execucao-reservas "osId:S pecaId:S" osId,pecaId
# GSI esparso pendentes (F5-i): o atributo pendente so existe enquanto a mensagem nao foi publicada.
criar_tabela execucao-outbox "id:S pendente:S criadoEm:S" id "$(gsi pendentes pendente criadoEm)"
criar_tabela execucao-idempotencia "messageId:S" messageId
criar_tabela execucao-tempos "servicoId:S" servicoId

ativar_ttl execucao-outbox expiraEm
ativar_ttl execucao-idempotencia expiraEm

echo "dynamodb criado: 6 tabelas execucao-*, 2 GSIs esparsos, TTL na outbox e na idempotencia"
