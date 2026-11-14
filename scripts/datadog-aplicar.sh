#!/usr/bin/env bash
# Aplica no Datadog os dashboards e monitores de observability/datadog/ (F8-g). Upsert pelo titulo (dashboard)
# ou pelo nome (monitor); NUNCA apaga nada. Nao toca a AWS nem o EKS.
#
# Uso: scripts/datadog-aplicar.sh [--conferir] [--dry-run] [--conta-nova] | --help
#   --conferir  so valida: JSON (jq), cada monitor em /api/v1/monitor/validate, cada metrica do metricas.txt
#               (obrigatoria = erro; '?' = aviso) e o estado dos percentis. Sai com 1 se algo falhar
#   --dry-run   valida como o --conferir e mostra o que criaria ou atualizaria, sem escrever
#   --conta-nova  conta sem metricas (trial novo): metrica obrigatoria ausente vira aviso em vez de erro. Depois da
#               1a subida, rodar de novo sem a flag para ligar os percentis e validar tudo
#   (sem flag)  valida, liga os percentis das distribuicoes (percentis.json) e faz o upsert
# Variaveis (do ambiente; nunca impressas): DATADOG_API_KEY, DATADOG_APP_KEY, DD_SITE (padrao datadoghq.com)
# A Application Key precisa dos escopos dashboards_read/write, monitors_read/write, metrics_read e
# a escrita de configuracao de tags de metricas (percentis).
set -euo pipefail

uso() { sed -n '2,/^set -euo/p' "${BASH_SOURCE[0]}" | grep '^#' | sed 's/^# \{0,1\}//'; }

CONFERIR=false
DRY_RUN=false
CONTA_NOVA=false
for arg in "$@"; do
  case "$arg" in
    --conferir) CONFERIR=true ;;
    --dry-run) DRY_RUN=true ;;
    --conta-nova) CONTA_NOVA=true ;;
    -h | --help) uso; exit 0 ;;
    *) echo "Argumento desconhecido: $arg" >&2; exit 1 ;;
  esac
done

for v in DATADOG_API_KEY DATADOG_APP_KEY; do
  [[ -n "${!v:-}" ]] || { echo "Variavel $v ausente (use scripts/atualizar-credenciais.sh --fixos e o workflow datadog.yml)" >&2; exit 1; }
done
command -v jq > /dev/null || { echo "jq nao encontrado" >&2; exit 1; }
DD_SITE="${DD_SITE:-datadoghq.com}"
BASE="${DD_API_URL:-https://api.$DD_SITE}"
RAIZ="$(cd "$(dirname "${BASH_SOURCE[0]}")/../observability/datadog" && pwd)"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
ERROS=0
RESUMO=()

erro() { echo "ERRO  $*" >&2; ERROS=$((ERROS + 1)); RESUMO+=("- ❌ $*"); }
aviso() { echo "AVISO $*"; RESUMO+=("- ⚠️ $*"); }
ok() { echo "OK    $*"; RESUMO+=("- ✅ $*"); }

# dd_api <metodo> <caminho> [arquivo-json]: corpo em $TMP/resp.json, imprime o status HTTP. As chaves vao por
# configuracao no stdin do curl, nunca por argumento (apareceriam no ps).
dd_api() {
  local metodo="$1" caminho="$2" corpo="${3:-}"
  local args=(--silent --show-error --max-time 30 --output "$TMP/resp.json" --write-out '%{http_code}' -X "$metodo"
    -H 'Content-Type: application/json' -K -)
  [[ -z "$corpo" ]] || args+=(--data-binary "@$corpo")
  printf 'header = "DD-API-KEY: %s"\nheader = "DD-APPLICATION-KEY: %s"\n' "$DATADOG_API_KEY" "$DATADOG_APP_KEY" \
    | curl "${args[@]}" "$BASE$caminho" || echo 000
}
detalhe() { jq -r '(.errors // .error // .) | tostring' "$TMP/resp.json" 2> /dev/null | head -c 300 || true; }

# ---------------------------------------------------------------------------------------------------------
echo "== JSON"
mapfile -t ARQUIVOS < <(find "$RAIZ" -name '*.json' | sort)
for f in "${ARQUIVOS[@]}"; do
  if jq empty "$f" 2> /dev/null; then ok "JSON valido: ${f#"$RAIZ/"}"; else erro "JSON invalido: ${f#"$RAIZ/"}"; fi
done

echo "== Chaves"
status=$(dd_api GET /api/v1/validate)
if [[ "$status" == 200 ]]; then ok "API key valida"; else erro "API key recusada (HTTP $status)"; fi
status=$(dd_api GET "/api/v1/dashboard?count=1")
if [[ "$status" == 200 ]]; then ok "Application Key aceita (dashboards_read)"; else erro "Application Key sem acesso aos dashboards (HTTP $status)"; fi

echo "== Monitores (validate)"
for f in "$RAIZ"/monitors/*.json; do
  status=$(dd_api POST /api/v1/monitor/validate "$f")
  if [[ "$status" == 200 ]]; then ok "monitor valido: $(jq -r .name "$f")"; else erro "monitor invalido ($(basename "$f"), HTTP $status): $(detalhe)"; fi
done

echo "== Metricas"
# Lista das metricas ativas nos ultimos 3 dias. Os endpoints por nome (GET /api/v1/metrics/<nome>, v2 all-tags)
# respondem 200 para metrica que a conta nunca recebeu, entao nao servem para provar a existencia.
status=$(dd_api GET "/api/v1/metrics?from=$(( $(date +%s) - 259200 ))")
if [[ "$status" == 200 ]]; then jq -r '.metrics[]?' "$TMP/resp.json" > "$TMP/ativas.txt"; else : > "$TMP/ativas.txt"; aviso "nao foi possivel listar as metricas (HTTP $status)"; fi
while IFS= read -r linha; do
  [[ -z "$linha" || "$linha" == \#* ]] && continue
  opcional=false
  [[ "$linha" == \?* ]] && { opcional=true; linha="${linha#\?}"; }
  if grep -qxF "$linha" "$TMP/ativas.txt"; then ok "metrica existe: $linha"
  elif $opcional; then aviso "metrica opcional ainda ausente: $linha"
  elif $CONTA_NOVA; then aviso "metrica ausente (conta nova): $linha"
  else erro "metrica ausente: $linha"; fi
done < "$RAIZ/metricas.txt"

echo "== Percentis"
# Percentis das distribuicoes vem desligados; as consultas pNN: dos dashboards e monitores exigem liga-los.
for metrica in $(jq -r 'keys[]' "$RAIZ/percentis.json"); do
  status=$(dd_api GET "/api/v2/metrics/$metrica/tags")
  if [[ "$status" == 200 ]]; then
    if [[ "$(jq -r '.data.attributes.include_percentiles // false' "$TMP/resp.json")" == true ]]; then
      ok "percentis ligados: $metrica"; continue
    fi
    existe=true
  elif [[ "$status" == 404 ]]; then existe=false
  else aviso "nao foi possivel ler a configuracao de $metrica (HTTP $status)"; continue; fi

  if $CONFERIR || $DRY_RUN; then
    aviso "percentis desligados: $metrica (o modo aplicar liga)"; continue
  fi
  jq -n --arg m "$metrica" --argjson t "$(jq --arg m "$metrica" '.[$m]' "$RAIZ/percentis.json")" \
    '{data: {type: "manage_tags", id: $m, attributes: {tags: $t, metric_type: "distribution", include_percentiles: true}}}' > "$TMP/pct.json"
  if $existe; then status=$(dd_api PATCH "/api/v2/metrics/$metrica/tags" "$TMP/pct.json"); else status=$(dd_api POST "/api/v2/metrics/$metrica/tags" "$TMP/pct.json"); fi
  # Metrica que ainda nao existe (ex.: mensagem.atraso antes da primeira subida) nao e erro: rodar de novo depois.
  if [[ "$status" == 200 || "$status" == 201 ]]; then ok "percentis ligados: $metrica"; else aviso "percentis nao ligados em $metrica (HTTP $status): $(detalhe)"; fi
done

# ---------------------------------------------------------------------------------------------------------
if [[ "$ERROS" -gt 0 ]]; then
  echo "== $ERROS erro(s); nada foi escrito" >&2
elif ! $CONFERIR; then
  echo "== Upsert"
  dd_api GET "/api/v1/dashboard" > /dev/null && jq '.dashboards' "$TMP/resp.json" > "$TMP/dashboards.json" || echo '[]' > "$TMP/dashboards.json"
  for f in "$RAIZ"/dashboards/*.json; do
    titulo=$(jq -r .title "$f")
    id=$(jq -r --arg t "$titulo" '[.[] | select(.title == $t)][0].id // empty' "$TMP/dashboards.json")
    if [[ -n "$id" ]]; then acao="atualizaria"; feito="atualizado"; metodo=PUT; caminho="/api/v1/dashboard/$id"; else acao="criaria"; feito="criado"; metodo=POST; caminho="/api/v1/dashboard"; fi
    if $DRY_RUN; then echo "   [dry-run] $acao dashboard: $titulo"; continue; fi
    status=$(dd_api "$metodo" "$caminho" "$f")
    if [[ "$status" == 200 ]]; then
      ok "dashboard $feito: $titulo -> https://app.$DD_SITE$(jq -r .url "$TMP/resp.json")"
    else erro "dashboard '$titulo' (HTTP $status): $(detalhe)"; fi
  done
  for f in "$RAIZ"/monitors/*.json; do
    nome=$(jq -r .name "$f")
    status=$(dd_api GET "/api/v1/monitor?monitor_tags=projeto:mecanica-fase4")
    id=""
    [[ "$status" == 200 ]] && id=$(jq -r --arg n "$nome" '[.[] | select(.name == $n)][0].id // empty' "$TMP/resp.json")
    if [[ -n "$id" ]]; then acao="atualizaria"; feito="atualizado"; metodo=PUT; caminho="/api/v1/monitor/$id"; else acao="criaria"; feito="criado"; metodo=POST; caminho="/api/v1/monitor"; fi
    if $DRY_RUN; then echo "   [dry-run] $acao monitor: $nome"; continue; fi
    status=$(dd_api "$metodo" "$caminho" "$f")
    if [[ "$status" == 200 ]]; then
      ok "monitor $feito: $nome -> https://app.$DD_SITE/monitors/$(jq -r .id "$TMP/resp.json")"
    else erro "monitor '$nome' (HTTP $status): $(detalhe)"; fi
  done
fi

if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
  { echo "### Datadog ($([[ "$CONFERIR" == true ]] && echo conferir || echo aplicar))"; printf '%s\n' "${RESUMO[@]}"; } >> "$GITHUB_STEP_SUMMARY"
fi
[[ "$ERROS" -eq 0 ]]
