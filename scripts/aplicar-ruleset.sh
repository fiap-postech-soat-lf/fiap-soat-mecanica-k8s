#!/usr/bin/env bash
# Aplica o ruleset "main-protegida" (scripts/ruleset-main.json) na branch padrao de um
# repositorio da org. Idempotente: atualiza o ruleset se ele ja existir.
#
# Antes de aplicar, confere se cada check obrigatorio ja passou no ultimo commit da
# main (ordem do T10: push -> CI verde -> ruleset). Se algum faltar, lista os checks
# encontrados e para; --forcar aplica mesmo assim.
#
# Uso: scripts/aplicar-ruleset.sh <repo> [--dry-run] [--forcar]
# Variaveis: ORG (padrao fiap-postech-soat-lf)
#            SONAR_CHECK (padrao "SonarCloud Code Analysis": nome do check do SonarCloud)
set -euo pipefail

ORG="${ORG:-fiap-postech-soat-lf}"
SONAR_CHECK="${SONAR_CHECK:-SonarCloud Code Analysis}"
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DRY_RUN=false
FORCAR=false
REPO=""

for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=true ;;
    --forcar) FORCAR=true ;;
    -*) echo "Opcao desconhecida: $arg" >&2; exit 1 ;;
    *) REPO="$arg" ;;
  esac
done
[[ -n "$REPO" ]] || { echo "Uso: $0 <repo> [--dry-run] [--forcar]" >&2; exit 1; }

# Checks obrigatorios pelo tipo do repositorio (tabela 3.1 do plano da F1).
case "$REPO" in
  fiap-soat-mecanica-db | fiap-soat-mecanica-k8s)
    checks=$(jq -nc '[{"context": "ci / terraform"}]') ;;
  fiap-soat-mecanica-identity | fiap-soat-mecanica-os | fiap-soat-mecanica-billing | \
    fiap-soat-mecanica-execucao | fiap-soat-mecanica-auth)
    checks=$(jq -nc --arg sonar "$SONAR_CHECK" '[{"context": "ci / build"}, {"context": $sonar}]') ;;
  *)
    echo "Repositorio desconhecido: $REPO" >&2; exit 1 ;;
esac

gh auth status >/dev/null 2>&1 || { echo "gh nao autenticado: rode 'gh auth login'" >&2; exit 1; }
branch=$(gh api "repos/$ORG/$REPO" --jq .default_branch) \
  || { echo "Repositorio $ORG/$REPO nao encontrado" >&2; exit 1; }
gh api "repos/$ORG/$REPO/branches/$branch" --jq .name >/dev/null 2>&1 \
  || { echo "A branch $branch ainda nao existe em $ORG/$REPO: faca o push inicial antes" >&2; exit 1; }

echo "== $ORG/$REPO (branch $branch)"

# Conclusao de cada check no ultimo commit (check runs de Actions e de apps como o SonarCloud).
encontrados=$(gh api "repos/$ORG/$REPO/commits/$branch/check-runs?per_page=100" \
  --jq '.check_runs[] | "\(.name)\t\(.conclusion // .status)"')
faltando=false
while IFS= read -r contexto; do
  conclusao=$(awk -F'\t' -v n="$contexto" '$1 == n { print $2; exit }' <<< "$encontrados")
  if [[ "$conclusao" == "success" ]]; then
    echo "   ok      $contexto"
  else
    echo "   FALTA   $contexto (${conclusao:-nao encontrado})"
    faltando=true
  fi
done < <(jq -r '.[].context' <<< "$checks")

if $faltando; then
  echo
  echo "Checks encontrados no ultimo commit de $branch:"
  if [[ -n "$encontrados" ]]; then
    awk '{ print "   " $0 }' <<< "$encontrados"
  else
    echo "   (nenhum)"
  fi
  if ! $FORCAR; then
    echo
    echo "Espere o CI ficar verde (gh run watch) ou ajuste SONAR_CHECK; --forcar aplica mesmo assim." >&2
    exit 1
  fi
  echo "--forcar: aplicando mesmo assim."
fi

payload=$(jq --argjson checks "$checks" \
  '(.rules[] | select(.type == "required_status_checks") | .parameters.required_status_checks) = $checks' \
  "$DIR/ruleset-main.json")

id=$(gh api "repos/$ORG/$REPO/rulesets" --jq '.[] | select(.name == "main-protegida") | .id')
if [[ -n "$id" ]]; then
  metodo=PUT
  caminho="repos/$ORG/$REPO/rulesets/$id"
else
  metodo=POST
  caminho="repos/$ORG/$REPO/rulesets"
fi

if $DRY_RUN; then
  echo
  echo "[dry-run] gh api --method $metodo $caminho --input - <<'JSON'"
  echo "$payload"
  echo "JSON"
  exit 0
fi

gh api --method "$metodo" "$caminho" --input - <<< "$payload" \
  --jq '"   ruleset \(.name) (id \(.id)): \(.enforcement)"'

echo
echo "Rulesets de $ORG/$REPO:"
gh api "repos/$ORG/$REPO/rulesets" --jq '.[] | "   \(.name) (id \(.id))"'
