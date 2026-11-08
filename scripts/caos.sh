#!/usr/bin/env bash
# Cenas de caos da F7 no EKS. ESCREVE DADOS: abre OS de verdade, mexe em replicas e (com --esgotar) no env do
# OS, manda mensagens para o SQS e limpa a DLQ. Nao rodar contra um ambiente que nao seja descartavel.
# Todo estado alterado e desfeito por um trap (replicas do Execucao e SAGA_TIMEOUT_COMANDO do OS).
#
# Cenas:
#   execucao-fora [--esgotar]   (F7-f, F7-g)
#     1. logins do atendente e do mecanico do seed; anota as replicas do Execucao (R0)
#     2. escala o mecanica-execucao para 0 (o HPA nao age com 0 replicas) e espera os pods sairem
#     3. POST /ordem-servicos (atendente, veiculo do seed) -> 201 RECEBIDA
#     4. espera o AbrirDiagnostico na mecanica-execucao-comandos e publica uma COPIA com o mesmo messageId
#        (duplicata real de SQS); o original volta a fila na hora (um so receive: contagem 1 de 5)
#     5. espera a fila chegar a 3 mensagens: original, copia e o REENVIO do OS pelo timeout (~2-2,5 min)
#     6. volta o Execucao para R0; a OS chega a EM_DIAGNOSTICO em ate 60 s
#     7. uma ordem no Execucao; mensagem_duplicada e comando_reemitido no log do Execucao e
#        resposta_fora_do_passo no log do OS
#     8. cancela a OS (limpeza)
#     --esgotar: antes do passo 2, kubectl set env deploy/mecanica-os SAGA_TIMEOUT_COMANDO=PT30S; o passo 5
#     passa a esperar a OS CANCELADA com sagaStatus FALHOU (3 tentativas esgotadas); depois do retorno do
#     Execucao, a ordem fica CANCELADA (ou lapide) e fora da fila. No fim o env do OS e desfeito.
#   mensagem-envenenada [--manter]   (F7-h)
#     1. a mecanica-execucao-comandos-dlq precisa estar com 0 mensagens
#     2. envia "isto-nao-e-json-<timestamp>" para a mecanica-execucao-comandos
#     3. espera (ate 5 min) a DLQ chegar a 1 (5 recebimentos de 30 s); mostra o ApproximateReceiveCount e as
#        linhas mensagem_falhou/json_invalido do log do Execucao
#     4. sem --manter: purge-queue da DLQ e confere 0 depois de 60 s
#
# Uso: scripts/caos.sh <cena> [flags] | --help
# Le do SSM /mecanica/auth/api-url, usa as filas pelo nome e kubectl (kubeconfig do cluster:
# aws eks update-kubeconfig --name <cluster>).
# Saida: 0 se a cena passar, 1 se algum passo falhar.
# Variaveis: AWS_REGION (padrao us-east-1), NAMESPACE (padrao mecanica)
set -euo pipefail

uso() { sed -n '2,/^set -euo/p' "${BASH_SOURCE[0]}" | grep '^#' | sed 's/^# \{0,1\}//'; }

CENA="${1:-}"
case "$CENA" in
  execucao-fora | mensagem-envenenada) shift ;;
  -h | --help) uso; exit 0 ;;
  *) uso >&2; echo >&2; echo "Cena desconhecida ou ausente: '$CENA'" >&2; exit 1 ;;
esac

ESGOTAR=false
MANTER=false
for arg in "$@"; do
  case "$arg" in
    --esgotar)
      [[ "$CENA" == execucao-fora ]] || { echo "--esgotar so vale em execucao-fora" >&2; exit 1; }
      ESGOTAR=true ;;
    --manter)
      [[ "$CENA" == mensagem-envenenada ]] || { echo "--manter so vale em mensagem-envenenada" >&2; exit 1; }
      MANTER=true ;;
    -h | --help) uso; exit 0 ;;
    *) echo "Argumento desconhecido: $arg" >&2; exit 1 ;;
  esac
done

export AWS_DEFAULT_REGION="${AWS_REGION:-us-east-1}"
NAMESPACE="${NAMESPACE:-mecanica}"
DEPLOY_EXECUCAO="mecanica-execucao"
DEPLOY_OS="mecanica-os"
FILA_COMANDOS="mecanica-execucao-comandos"
FILA_DLQ="mecanica-execucao-comandos-dlq"

# Dados do seed do Identity (V5__seed.sql) e do OS (V6__seed.sql).
EMAIL_ATENDENTE_SEED="atendente@mecanica.test"
EMAIL_MECANICO_SEED="mecanico@mecanica.test"
SENHA_SEED="Senha@123"
VEICULO_ID_SEED="44444444-4444-4444-4444-444444444444"

TMP=$(mktemp -d)
umask 077
INICIO=$(date -u +%Y-%m-%dT%H:%M:%SZ)
REPLICAS_ORIGINAIS=""
EXECUCAO_ESCALADO=false
ENV_OS_ALTERADO=false

ssm() { aws ssm get-parameter --name "$1" --query Parameter.Value --output text; }
passo() { printf 'PASS  %-3s %s\n' "$1" "$2"; }
falhar() {
  printf 'FAIL  %-3s %s\n' "$1" "$2" >&2
  exit 1
}

# Desfaz o que a cena mexeu, qualquer que seja a saida, e mostra o estado final dos deployments.
limpar() {
  local rc=$?
  set +e
  if $EXECUCAO_ESCALADO; then
    echo "-- trap: Execucao de volta a $REPLICAS_ORIGINAIS replica(s)"
    kubectl scale "deploy/$DEPLOY_EXECUCAO" --replicas="$REPLICAS_ORIGINAIS" -n "$NAMESPACE"
  fi
  if $ENV_OS_ALTERADO; then
    echo "-- trap: SAGA_TIMEOUT_COMANDO removido do OS"
    kubectl set env "deploy/$DEPLOY_OS" SAGA_TIMEOUT_COMANDO- -n "$NAMESPACE"
    kubectl rollout status "deploy/$DEPLOY_OS" -n "$NAMESPACE" --timeout=300s
  fi
  if $EXECUCAO_ESCALADO || $ENV_OS_ALTERADO; then
    kubectl get deploy -n "$NAMESPACE"
  fi
  rm -rf "$TMP"
  return "$rc"
}
trap limpar EXIT

# api <token> <metodo> <caminho> [corpo]: devolve o corpo em $TMP/resp.json e imprime o status HTTP.
api() {
  local token="$1" metodo="$2" caminho="$3" corpo="${4:-}"
  local args=(--silent --show-error --max-time 20 --output "$TMP/resp.json" --write-out '%{http_code}'
    -X "$metodo" -H 'Content-Type: application/json' -H "Authorization: Bearer $token")
  [[ -n "$corpo" ]] && args+=(--data "$corpo")
  curl "${args[@]}" "$API$caminho" || true
}

resumo() { head -c 300 "$TMP/resp.json" 2> /dev/null || true; }

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

campo_os() { # campo_os <osId> <campo>
  [[ "$(api "$TOKEN_ATENDENTE" GET "/ordem-servicos/$1")" == 200 ]] && jq -r ".$2 // empty" "$TMP/resp.json"
}
os_tem() { [[ "$(campo_os "$1" "$2")" == "$3" ]]; } # os_tem <osId> <campo> <valor>
status_execucao() { # status_execucao <osId>: status da ordem, ou "404"
  local status
  status=$(api "$TOKEN_MECANICO" GET "/execucoes/$1")
  if [[ "$status" == 200 ]]; then jq -r '.status // empty' "$TMP/resp.json"; else echo "$status"; fi
}
na_fila() { # na_fila <osId>: 0 se a ordem esta em GET /execucoes/fila
  [[ "$(api "$TOKEN_MECANICO" GET "/execucoes/fila?size=100")" == 200 ]] \
    && jq -e --arg os "$1" '.itens | map(.osId) | index($os) != null' "$TMP/resp.json" > /dev/null
}

url_fila() { aws sqs get-queue-url --queue-name "$1" --query QueueUrl --output text; }
atributo_fila() { # atributo_fila <url> <atributo>
  aws sqs get-queue-attributes --queue-url "$1" --attribute-names "$2" --query "Attributes.$2" --output text
}
profundidade() { atributo_fila "$1" ApproximateNumberOfMessages; }
em_voo() { atributo_fila "$1" ApproximateNumberOfMessagesNotVisible; }
fila_com_pelo_menos() { [[ "$(profundidade "$1")" -ge "$2" ]]; } # fila_com_pelo_menos <url> <n>
pods_do() { kubectl get pods -l "app=$1" -n "$NAMESPACE" --no-headers 2> /dev/null | wc -l; }
sem_pods() { [[ "$(pods_do "$1")" -eq 0 ]]; }
logs_de() { # logs_de <app>: log desde o inicio da cena
  kubectl logs -l "app=$1" -n "$NAMESPACE" --since-time="$INICIO" --tail=-1 2> /dev/null
}

abrir_os() { # abrir_os <observacao>: imprime o id da OS RECEBIDA
  local status
  status=$(api "$TOKEN_ATENDENTE" POST /ordem-servicos "{\"veiculoId\":\"$VEICULO_ID_SEED\",\"observacao\":\"$1\"}")
  [[ "$status" == 201 && "$(jq -r .situacao "$TMP/resp.json")" == RECEBIDA ]] || return 1
  jq -r .id "$TMP/resp.json"
}

API=$(ssm /mecanica/auth/api-url)
API="${API%/}"
echo "API: $API"
echo "Cena: $CENA$($ESGOTAR && echo ' --esgotar')$($MANTER && echo ' --manter')"
echo

# ---------------------------------------------------------------------------------------------------------
cena_execucao_fora() {
  local os_id url_comandos corpo recibo atual

  # 1. Logins e estado de partida.
  TOKEN_ATENDENTE=$(login "$EMAIL_ATENDENTE_SEED") || falhar 1 "login do atendente"
  TOKEN_MECANICO=$(login "$EMAIL_MECANICO_SEED") || falhar 1 "login do mecanico"
  REPLICAS_ORIGINAIS=$(kubectl get "deploy/$DEPLOY_EXECUCAO" -n "$NAMESPACE" -o jsonpath='{.spec.replicas}') \
    || falhar 1 "kubectl get deploy/$DEPLOY_EXECUCAO (confira o kubeconfig: aws eks update-kubeconfig --name <cluster>)"
  # Uma rodada anterior que morreu sem trap deixaria 0: volta para 1 (minReplicas do HPA).
  [[ "${REPLICAS_ORIGINAIS:-0}" -ge 1 ]] || REPLICAS_ORIGINAIS=1
  url_comandos=$(url_fila "$FILA_COMANDOS") || falhar 1 "fila $FILA_COMANDOS nao existe"
  [[ "$(profundidade "$url_comandos")" == 0 && "$(em_voo "$url_comandos")" == 0 ]] \
    || falhar 1 "$FILA_COMANDOS nao esta vazia; deixe o Execucao drenar a fila antes da cena"
  passo 1 "logins ok; Execucao com $REPLICAS_ORIGINAIS replica(s) (R0); $FILA_COMANDOS vazia"

  # Esgotamento: prazo de 30 s por comando, so durante a cena (sem PR).
  if $ESGOTAR; then
    kubectl set env "deploy/$DEPLOY_OS" SAGA_TIMEOUT_COMANDO=PT30S -n "$NAMESPACE" || falhar 1 "kubectl set env no OS"
    ENV_OS_ALTERADO=true
    kubectl rollout status "deploy/$DEPLOY_OS" -n "$NAMESPACE" --timeout=300s || falhar 1 "rollout do OS com PT30S"
    TOKEN_ATENDENTE=$(login "$EMAIL_ATENDENTE_SEED") || falhar 1 "login do atendente depois do rollout"
    passo 1 "SAGA_TIMEOUT_COMANDO=PT30S no OS (sera desfeito no fim)"
  fi

  # 2. Execucao fora do ar.
  EXECUCAO_ESCALADO=true
  kubectl scale "deploy/$DEPLOY_EXECUCAO" --replicas=0 -n "$NAMESPACE" || falhar 2 "kubectl scale para 0"
  esperar 36 5 sem_pods "$DEPLOY_EXECUCAO" || falhar 2 "os pods do Execucao nao sairam em 3 min"
  passo 2 "Execucao escalado para 0 (nenhum pod)"

  # 3. A OS e aberta com o consumidor parado.
  os_id=$(abrir_os "caos: Execucao fora do ar (F7)") || falhar 3 "POST /ordem-servicos: $(resumo)"
  passo 3 "POST /ordem-servicos -> 201 RECEBIDA (osId $os_id)"

  # 4. Duplicata real: copia o AbrirDiagnostico e o publica de novo com o mesmo messageId.
  esperar 30 2 fila_com_pelo_menos "$url_comandos" 1 \
    || falhar 4 "nenhum comando em $FILA_COMANDOS em 1 min (confira o log outbox_publicacao_falhou do OS)"
  aws sqs receive-message --queue-url "$url_comandos" --max-number-of-messages 1 --wait-time-seconds 10 \
    --visibility-timeout 30 > "$TMP/recebida.json" || falhar 4 "receive-message"
  corpo=$(jq -er '.Messages[0].Body' "$TMP/recebida.json") || falhar 4 "nenhuma mensagem recebida de $FILA_COMANDOS"
  recibo=$(jq -er '.Messages[0].ReceiptHandle' "$TMP/recebida.json")
  # O original volta a fila na hora, com contagem de recebimentos 1 de 5.
  aws sqs change-message-visibility --queue-url "$url_comandos" --receipt-handle "$recibo" --visibility-timeout 0 \
    || falhar 4 "change-message-visibility"
  jq -e --arg os "$os_id" '.type == "AbrirDiagnostico" and .osId == $os' <<< "$corpo" > /dev/null \
    || falhar 4 "a mensagem copiada nao e o AbrirDiagnostico da OS $os_id: ${corpo:0:200}"
  aws sqs send-message --queue-url "$url_comandos" --message-body "$corpo" > /dev/null || falhar 4 "send-message da copia"
  passo 4 "AbrirDiagnostico $(jq -r .messageId <<< "$corpo") copiado e republicado (mesmo messageId)"

  # 5. Aguarda o timeout do OS (reenvio) ou o esgotamento.
  if $ESGOTAR; then
    esperar 72 5 os_tem "$os_id" situacao CANCELADA \
      || falhar 5 "OS $os_id continua $(campo_os "$os_id" situacao || true) apos 6 min (esperado CANCELADA pelo esgotamento)"
    esperar 12 5 os_tem "$os_id" sagaStatus FALHOU \
      || falhar 5 "Saga da OS $os_id: '$(campo_os "$os_id" sagaStatus || true)', esperado FALHOU"
    passo 5 "tentativas esgotadas: OS CANCELADA e Saga FALHOU"
  else
    esperar 36 10 fila_com_pelo_menos "$url_comandos" 3 \
      || falhar 5 "a fila nao chegou a 3 mensagens em 6 min ($(profundidade "$url_comandos") agora; o prazo PT2M mudou?)"
    os_tem "$os_id" situacao RECEBIDA \
      || falhar 5 "OS $os_id esta $(campo_os "$os_id" situacao || true), esperado RECEBIDA ate o Execucao voltar"
    passo 5 "fila com 3 mensagens (original, copia e reenvio do OS); OS continua RECEBIDA"
  fi

  # 6. O Execucao volta.
  kubectl scale "deploy/$DEPLOY_EXECUCAO" --replicas="$REPLICAS_ORIGINAIS" -n "$NAMESPACE" || falhar 6 "kubectl scale para $REPLICAS_ORIGINAIS"
  EXECUCAO_ESCALADO=false
  kubectl rollout status "deploy/$DEPLOY_EXECUCAO" -n "$NAMESPACE" --timeout=300s || falhar 6 "o Execucao nao ficou pronto"
  if $ESGOTAR; then
    esperar 45 2 ordem_cancelada_ou_lapide "$os_id" \
      || falhar 6 "ordem $os_id no Execucao: '$(status_execucao "$os_id")', esperado CANCELADA ou 404 (lapide)"
    if na_fila "$os_id"; then falhar 6 "a ordem da OS cancelada aparece em GET /execucoes/fila"; fi
    passo 6 "Execucao de volta; ordem '$(status_execucao "$os_id")' e fora da fila"
    echo
    echo "Caos (esgotamento): tudo OK (osId $os_id)."
    return 0
  fi
  esperar 30 2 os_tem "$os_id" situacao EM_DIAGNOSTICO \
    || falhar 6 "OS $os_id continua $(campo_os "$os_id" situacao || true) 60 s depois da volta (confira consumidor_iniciado no Execucao; se estiver CANCELADA, o Execucao voltou depois do 3o prazo)"
  passo 6 "Execucao de volta a $REPLICAS_ORIGINAIS replica(s); OS EM_DIAGNOSTICO"

  # 7. Uma ordem e os dois niveis de idempotencia nos logs.
  atual=$(status_execucao "$os_id")
  [[ "$atual" == EM_DIAGNOSTICO ]] || falhar 7 "GET /execucoes/$os_id: '$atual', esperado EM_DIAGNOSTICO"
  na_fila "$os_id" || falhar 7 "a ordem da OS $os_id nao esta em GET /execucoes/fila"
  jq -e --arg os "$os_id" '[.itens[] | select(.osId == $os)] | length == 1' "$TMP/resp.json" > /dev/null \
    || falhar 7 "mais de uma ordem para a OS $os_id em GET /execucoes/fila"
  esperar 15 2 logs_execucao_ok "$os_id" \
    || falhar 7 "log do Execucao sem mensagem_duplicada (AbrirDiagnostico) ou sem comando_reemitido da OS $os_id"
  esperar 15 2 log_os_resposta_fora "$os_id" \
    || falhar 7 "log do OS sem resposta_fora_do_passo da OS $os_id"
  passo 7 "1 ordem; mensagem_duplicada e comando_reemitido no Execucao; resposta_fora_do_passo no OS"

  # 8. Limpeza.
  [[ "$(api "$TOKEN_ATENDENTE" PATCH "/ordem-servicos/$os_id/cancelar" '{"motivo":"caos: limpeza"}')" == 200 ]] \
    || falhar 8 "PATCH /cancelar da OS $os_id: $(resumo)"
  esperar 15 2 os_tem "$os_id" situacao CANCELADA || falhar 8 "OS $os_id nao ficou CANCELADA"
  passo 8 "OS $os_id cancelada (limpeza)"

  echo
  echo "Caos (Execucao fora do ar): tudo OK (osId $os_id)."
}

ordem_cancelada_ou_lapide() { # a lapide aparece como 404 (sem ordem) ou como CANCELADA
  local s
  s=$(status_execucao "$1")
  [[ "$s" == CANCELADA || "$s" == 404 ]]
}
logs_execucao_ok() { # logs_execucao_ok <osId>: duplicata (por tipo, sem osId no log) e reenvio (por OS)
  local log
  log=$(logs_de mecanica-execucao)
  grep 'mensagem_duplicada' <<< "$log" | grep -q 'AbrirDiagnostico' \
    && grep 'comando_reemitido' <<< "$log" | grep -q "$1"
}
log_os_resposta_fora() { logs_de mecanica-os | grep 'resposta_fora_do_passo' | grep -q "$1"; }

# ---------------------------------------------------------------------------------------------------------
cena_mensagem_envenenada() {
  local url_comandos url_dlq corpo total

  url_comandos=$(url_fila "$FILA_COMANDOS") || falhar 1 "fila $FILA_COMANDOS nao existe"
  url_dlq=$(url_fila "$FILA_DLQ") || falhar 1 "fila $FILA_DLQ nao existe"
  [[ "$(pods_do "$DEPLOY_EXECUCAO")" -ge 1 ]] || falhar 1 "o Execucao nao tem pods (confira o kubeconfig e o deployment)"

  # 1. DLQ de partida.
  total=$(profundidade "$url_dlq")
  [[ "$total" == 0 && "$(em_voo "$url_dlq")" == 0 ]] || falhar 1 "$FILA_DLQ ja tem mensagens ($total); limpe antes (aws sqs purge-queue)"
  passo 1 "$FILA_DLQ com 0 mensagens"

  # 2. A mensagem que nao e JSON.
  corpo="isto-nao-e-json-$(date +%s)"
  aws sqs send-message --queue-url "$url_comandos" --message-body "$corpo" > /dev/null || falhar 2 "send-message"
  passo 2 "mensagem '$corpo' enviada para $FILA_COMANDOS"

  # 3. Cinco recebimentos de 30 s e a DLQ.
  esperar 30 10 fila_com_pelo_menos "$url_dlq" 1 \
    || falhar 3 "a DLQ nao chegou a 1 em 5 min (confira o RedrivePolicy: aws sqs get-queue-attributes --attribute-names RedrivePolicy, e a visibilidade de 30 s)"
  aws sqs receive-message --queue-url "$url_dlq" --max-number-of-messages 1 --visibility-timeout 0 \
    --message-system-attribute-names ApproximateReceiveCount > "$TMP/dlq.json" || falhar 3 "receive-message da DLQ"
  echo "   corpo na DLQ: $(jq -r '.Messages[0].Body' "$TMP/dlq.json")"
  echo "   ApproximateReceiveCount: $(jq -r '.Messages[0].Attributes.ApproximateReceiveCount' "$TMP/dlq.json") (5 do consumidor + 1 desta leitura)"
  logs_de mecanica-execucao | grep mensagem_falhou | grep json_invalido > "$TMP/falhas.log" || true
  [[ -s "$TMP/falhas.log" ]] || falhar 3 "nenhum mensagem_falhou/json_invalido no log do Execucao"
  echo "   mensagem_falhou/json_invalido no log do Execucao: $(wc -l < "$TMP/falhas.log") linha(s)"
  head -1 "$TMP/falhas.log" | cut -c1-240 | sed 's/^/   /'
  passo 3 "DLQ com $(profundidade "$url_dlq") mensagem(ns); o dlq.depth deste momento e a amostra para o monitor da F8"

  # 4. Limpeza.
  if $MANTER; then
    passo 4 "--manter: DLQ deixada com a mensagem (limpe depois: aws sqs purge-queue --queue-url $url_dlq)"
  else
    if ! aws sqs purge-queue --queue-url "$url_dlq" 2> "$TMP/purge.err"; then
      # purge-queue so aceita uma chamada por fila a cada 60 s.
      echo "   purge-queue recusado ($(head -c 120 "$TMP/purge.err")); nova tentativa em 60 s"
      sleep 60
      aws sqs purge-queue --queue-url "$url_dlq" || falhar 4 "purge-queue da DLQ"
    fi
    sleep 60
    [[ "$(profundidade "$url_dlq")" == 0 ]] || falhar 4 "a DLQ ainda tem $(profundidade "$url_dlq") mensagem(ns) 60 s depois do purge"
    passo 4 "DLQ limpa (0 mensagens)"
  fi

  echo
  echo "Caos (mensagem envenenada): tudo OK."
}

case "$CENA" in
  execucao-fora) cena_execucao_fora ;;
  mensagem-envenenada) cena_mensagem_envenenada ;;
esac
