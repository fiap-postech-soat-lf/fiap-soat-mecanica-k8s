#!/usr/bin/env bash
# Gera um microsservico a partir de templates/servico-base/ (T12 do plano da F1).
#
# Copia, troca de tokens e remocoes da variante acontecem num diretorio temporario; so o
# resultado final e copiado para o destino, preservando o .git dele. O template nunca e alterado.
# Sem --forcar, para se o destino ja tiver qualquer arquivo alem do .git.
#
# Uso: scripts/novo-servico.sh <identity|os|billing|execucao> <sql|dynamo> [--destino DIR] [--forcar] [--sem-verify]
#   --destino     pasta onde fica fiap-soat-mecanica-<svc> (padrao $WORKSPACE ou /home/rede/git/fase4)
#   --forcar      regrava os arquivos do template num destino que ja tem conteudo; arquivos que nao
#                 vem do template (codigo de dominio) sao mantidos. Revise com git diff depois.
#   --sem-verify  nao roda o ./mvnw verify no fim (precisa de Docker para os Testcontainers)
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RAIZ="$(cd "$DIR/.." && pwd)"
TEMPLATE="$RAIZ/templates/servico-base"
DESTINO_BASE="${WORKSPACE:-/home/rede/git/fase4}"
FORCAR=false
VERIFY=true
args=()

uso() { echo "Uso: $0 <identity|os|billing|execucao> <sql|dynamo> [--destino DIR] [--forcar] [--sem-verify]" >&2; exit 1; }
falhar() { echo "ERRO: $*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --destino) [[ $# -ge 2 ]] || uso; DESTINO_BASE="$2"; shift 2 ;;
    --forcar) FORCAR=true; shift ;;
    --sem-verify) VERIFY=false; shift ;;
    -*) echo "Opcao desconhecida: $1" >&2; uso ;;
    *) args+=("$1"); shift ;;
  esac
done
[[ ${#args[@]} -eq 2 ]] || uso
SVC="${args[0]}"
MODO="${args[1]}"

# Tabelas 3.1 (variante), 3.3 (portas locais) e 7.4 (rotas) do plano da F1.
PG=""
case "$SVC" in
  identity) CLASSE=Identity; PORTA=8081; PG=5433; ESPERADO=sql; ROTAS=(/auth /clientes /veiculos /usuarios) ;;
  os) CLASSE=Os; PORTA=8082; PG=5434; ESPERADO=sql; ROTAS=(/ordem-servicos /servicos) ;;
  billing) CLASSE=Billing; PORTA=8083; PG=5435; ESPERADO=sql; ROTAS=(/webhooks/mercadopago /orcamentos /pagamentos) ;;
  execucao) CLASSE=Execucao; PORTA=8084; ESPERADO=dynamo; ROTAS=(/execucoes /prestacoes /pecas /alocacoes) ;;
  *) falhar "servico desconhecido: $SVC (identity, os, billing ou execucao)" ;;
esac
[[ "$MODO" == sql || "$MODO" == dynamo ]] || uso
[[ "$MODO" == "$ESPERADO" ]] || falhar "$SVC usa a variante $ESPERADO (tabela 3.1), nao $MODO"

[[ -d "$TEMPLATE" ]] || falhar "template nao encontrado em $TEMPLATE"
mkdir -p "$DESTINO_BASE"
ALVO="$(cd "$DESTINO_BASE" && pwd)/fiap-soat-mecanica-$SVC"
case "$ALVO/" in "$RAIZ"/*) falhar "o destino nao pode ficar dentro do -k8s ($RAIZ)" ;; esac

if [[ -d "$ALVO" ]] && [[ -n "$(find "$ALVO" -mindepth 1 -maxdepth 1 ! -name .git -print -quit)" ]]; then
  $FORCAR || falhar "$ALVO ja tem conteudo alem do .git; use --forcar para regravar os arquivos do template"
  echo "AVISO: --forcar: os arquivos do template serao regravados em $ALVO"
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
STAGE="$TMP/fiap-soat-mecanica-$SVC"
mkdir "$STAGE"

echo "== fiap-soat-mecanica-$SVC ($MODO) a partir de $TEMPLATE"

# 1) Copia os arquivos do template conhecidos pelo git (sem target/ e outros ignorados).
(
  cd "$TEMPLATE"
  git ls-files -co --exclude-standard -z | while IFS= read -r -d '' f; do
    if [[ -e "$f" ]]; then printf '%s\0' "$f"; fi
  done | tar --null -cf - -T -
) | tar -xf - -C "$STAGE"

# Arquivos de texto do staging que contem o padrao (lista vazia nao e erro).
arquivos_com() { grep -rlIE "$1" "$STAGE" || true; }

remover_blocos() {
  local marca="$1" f
  while IFS= read -r f; do
    [[ -n "$f" ]] || continue
    sed -i -E "/(<!--|#|\/\/) *\[$marca\]/,/(<!--|#|\/\/) *\[\/$marca\]/d" "$f"
  done <<< "$(arquivos_com "(<!--|#|//) *\[$marca\]")"
}

# 2) Variante: remove os blocos da outra variante e depois as linhas de marcador que sobraram.
if [[ "$MODO" == dynamo ]]; then
  find "$STAGE/src" -type d -path '*/persistence/mensageria' -prune -exec rm -rf {} +
  rm -rf "$STAGE/src/main/resources/db"
  find "$STAGE/src" -mindepth 1 -type d -empty -delete
  remover_blocos SQL
  sed -i 's/^app\.messaging\.consumidor\.enabled=.*/app.messaging.consumidor.enabled=false/' \
    "$STAGE/src/main/resources/application.properties"
else
  remover_blocos DYNAMO
fi
while IFS= read -r f; do
  [[ -n "$f" ]] || continue
  sed -i -E '/^[[:space:]]*(<!--|#|\/\/) *\[\/?(SQL|DYNAMO)\]( *-->)?[[:space:]]*$/d' "$f"
done <<< "$(arquivos_com '\[/?(SQL|DYNAMO)\]')"

# 3) Tokens e pacote Java.
while IFS= read -r f; do
  [[ -n "$f" ]] || continue
  sed -i "s/ServicoBase/$CLASSE/g; s/servicobase/$SVC/g" "$f"
done <<< "$(arquivos_com 'servicobase|ServicoBase')"
for raiz_java in src/main/java src/test/java; do
  mv "$STAGE/$raiz_java/br/com/fiap/soat/mecanica/servicobase" "$STAGE/$raiz_java/br/com/fiap/soat/mecanica/$SVC"
done
mv "$STAGE/src/main/java/br/com/fiap/soat/mecanica/$SVC/ServicoBaseApplication.java" \
  "$STAGE/src/main/java/br/com/fiap/soat/mecanica/$SVC/${CLASSE}Application.java"

# 4) Porta e Postgres locais (tabela 3.3).
LOCAL="$STAGE/src/main/resources/application-local.properties"
grep -q '^server\.port=8080$' "$LOCAL" || falhar "server.port=8080 nao encontrado em application-local.properties"
sed -i "s/^server\.port=8080$/server.port=$PORTA/" "$LOCAL"
sed -i "s#localhost:8080#localhost:$PORTA#g" "$STAGE/README.md"
if [[ -n "$PG" ]]; then
  grep -q 'localhost:5433/' "$LOCAL" || falhar "datasource localhost:5433 nao encontrado em application-local.properties"
  sed -i "s#localhost:5433/#localhost:$PG/#" "$LOCAL"
fi

# 5) Rotas do IngressRoute (tabela 7.4).
match=""
for rota in "${ROTAS[@]}"; do
  match+="${match:+ || }PathPrefix(\`$rota\`)"
done
INGRESS="$STAGE/k8s/ingressroute.yaml"
sed -i '/Trocado pelo novo-servico.sh/d' "$INGRESS"
sed -i "s#__ROTAS_MATCH__#$match#" "$INGRESS"

# 6) CLAUDE.md (ignorado pelo gitignore global: fica so local) e LICENSE do -k8s.
mv "$STAGE/CLAUDE.md.tmpl" "$STAGE/CLAUDE.md"
cp "$RAIZ/LICENSE" "$STAGE/LICENSE"

# 7) Conferencias antes de copiar para o destino.
sobras="$(grep -rnIE 'servicobase|ServicoBase|__ROTAS_MATCH__|\[/?(SQL|DYNAMO)\]' "$STAGE" || true)"
[[ -z "$sobras" ]] || falhar "sobraram tokens ou marcadores:"$'\n'"$sobras"
if [[ "$MODO" == dynamo ]]; then
  sobras="$(grep -rnE 'jakarta\.persistence|springframework\.data|flyway|PostgreSQL|datasource' \
    --include='*.java' --include='*.xml' --include='*.properties' "$STAGE" || true)"
  [[ -z "$sobras" ]] || falhar "sobrou referencia a SQL na variante dynamo:"$'\n'"$sobras"
fi

# 8) Copia para o destino (o .git do destino nao e tocado).
mkdir -p "$ALVO"
cp -a "$STAGE/." "$ALVO/"
echo "   gerado em $ALVO"

if ! $VERIFY; then
  echo "   verify pulado (--sem-verify)"
  exit 0
fi

mkdir -p "$ALVO/target"
LOG="$ALVO/target/novo-servico-verify.log"
echo "   ./mvnw verify (log em $LOG)..."
if (cd "$ALVO" && ./mvnw -B verify > "$LOG" 2>&1); then
  echo "   OK: $(grep -E 'Tests run: [0-9]+, Failures' "$LOG" | tail -1 | sed 's/^\[INFO\] //')"
else
  tail -40 "$LOG" >&2
  falhar "./mvnw verify falhou em $ALVO (log completo em $LOG)"
fi
