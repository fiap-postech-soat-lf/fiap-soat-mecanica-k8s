#!/usr/bin/env bash
# Grava os secrets da org usados pelos workflows. Idempotente: sobrescreve o valor atual.
#
# Uso:
#   scripts/atualizar-credenciais.sh [--dry-run]           # 3 secrets AWS a partir do perfil local
#   scripts/atualizar-credenciais.sh --fixos [--dry-run]   # Datadog (API e Application Key), SonarCloud e Mercado Pago
# Variaveis: ORG (padrao fiap-postech-soat-lf), AWS_PROFILE (padrao default)
#
# Rodar sem argumentos no inicio de TODA sessao do AWS Academy (as credenciais expiram).
# Nenhum valor e impresso: o valor vai para o gh pela entrada padrao, nunca por argumento
# (argumentos aparecem no `ps` e no historico).
set -euo pipefail

ORG="${ORG:-fiap-postech-soat-lf}"
PERFIL="${AWS_PROFILE:-default}"
DRY_RUN=false
FIXOS=false

for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=true ;;
    --fixos) FIXOS=true ;;
    -h|--help) sed -n '2,11p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Argumento desconhecido: $arg" >&2; exit 1 ;;
  esac
done

# Grava um secret da org com visibilidade all (no plano Free so chega a repos publicos).
# Com o 3o argumento (repositorio), a visibilidade e selected: so esse repositorio enxerga o secret.
gravar() {
  local nome="$1" valor="$2" repo="${3:-}"
  local escopo=(--visibility all)
  [[ -z "$repo" ]] || escopo=(--visibility selected --repos "$repo")
  if $DRY_RUN; then
    echo "   [dry-run] gh secret set $nome --org $ORG ${escopo[*]} (${#valor} caracteres)"
  else
    printf '%s' "$valor" | gh secret set "$nome" --org "$ORG" "${escopo[@]}"
    echo "   $nome gravado"
  fi
}

# Remove espacos e quebras de linha nas pontas (comum ao colar no terminal).
aparar() {
  local v="$1"
  v="${v#"${v%%[![:space:]]*}"}"
  v="${v%"${v##*[![:space:]]}"}"
  printf '%s' "$v"
}

gh auth status >/dev/null 2>&1 || { echo "gh nao autenticado: rode 'gh auth login'" >&2; exit 1; }
# Listar secrets da org exige o escopo admin:org: falha aqui em vez de no meio da gravacao.
gh api "orgs/$ORG/actions/secrets" --silent 2>/dev/null \
  || { echo "Sem acesso aos secrets da org $ORG: rode 'gh auth refresh -s admin:org'" >&2; exit 1; }

if $FIXOS; then
  echo "== Secrets fixos da org $ORG (Enter vazio pula o secret)"
  for nome in DATADOG_API_KEY DATADOG_APP_KEY SONAR_TOKEN MP_ACCESS_TOKEN MP_WEBHOOK_SECRET; do
    valor=""
    read -rs -p "$nome: " valor || true
    echo >&2
    valor="$(aparar "$valor")"
    if [[ -z "$valor" ]]; then
      echo "   $nome pulado"
    else
      # A Application Key escreve dashboards e monitores: so o -k8s (datadog.yml) a enxerga.
      if [[ "$nome" == DATADOG_APP_KEY ]]; then gravar "$nome" "$valor" fiap-soat-mecanica-k8s; else gravar "$nome" "$valor"; fi
    fi
  done
  unset valor
else
  echo "== Credenciais AWS do perfil '$PERFIL'"
  command -v aws >/dev/null || { echo "AWS CLI nao encontrada" >&2; exit 1; }
  access_key="$(aws configure get aws_access_key_id --profile "$PERFIL" || true)"
  secret_key="$(aws configure get aws_secret_access_key --profile "$PERFIL" || true)"
  session_token="$(aws configure get aws_session_token --profile "$PERFIL" || true)"
  if [[ -z "$access_key" || -z "$secret_key" || -z "$session_token" ]]; then
    echo "Perfil '$PERFIL' incompleto: cole o bloco de 'AWS Details -> AWS CLI' do Academy em ~/.aws/credentials" >&2
    exit 1
  fi

  conta="$(aws sts get-caller-identity --profile "$PERFIL" --query Account --output text 2>/dev/null)" \
    || { echo "Credenciais invalidas ou expiradas: reinicie o Learner Lab e copie o bloco de novo" >&2; exit 1; }
  echo "   conta AWS: $conta"

  gravar AWS_ACCESS_KEY_ID "$access_key"
  gravar AWS_SECRET_ACCESS_KEY "$secret_key"
  gravar AWS_SESSION_TOKEN "$session_token"
  unset access_key secret_key session_token
fi

echo
echo "Secrets da org $ORG:"
gh secret list --org "$ORG" --json name,updatedAt,visibility \
  --jq '.[] | "  \(.name) (\(.visibility), atualizado em \(.updatedAt))"'
