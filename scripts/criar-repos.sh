#!/usr/bin/env bash
# Cria os 7 repositorios da Fase 4 na org, aplica as configuracoes padrao e
# clona cada um no workspace local. Idempotente: pode rodar de novo.
#
# Uso: scripts/criar-repos.sh [--dry-run]
# Variaveis: ORG (padrao fiap-postech-soat-lf), WORKSPACE (padrao /home/rede/git/fase4)
set -euo pipefail

ORG="${ORG:-fiap-postech-soat-lf}"
WORKSPACE="${WORKSPACE:-/home/rede/git/fase4}"
DRY_RUN=false
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=true

# Ordem fixa (array associativo nao preserva ordem): "repo|descricao"
REPOS=(
  "fiap-soat-mecanica-k8s|Fase 4 — EKS, add-ons compartilhados, reusable workflows e template dos serviços"
  "fiap-soat-mecanica-db|Fase 4 — Módulo Terraform rds-postgres"
  "fiap-soat-mecanica-auth|Fase 4 — Lambda Authorizer + API Gateway"
  "fiap-soat-mecanica-identity|Fase 4 — Identity: clientes, veículos, funcionários, login e notificações"
  "fiap-soat-mecanica-os|Fase 4 — OS Service: ordens de serviço, catálogo e orquestrador da Saga"
  "fiap-soat-mecanica-billing|Fase 4 — Billing: orçamento e pagamento (Mercado Pago)"
  "fiap-soat-mecanica-execucao|Fase 4 — Execução: diagnóstico, fila de execução, peças e estoque (DynamoDB)"
)

run() {
  if $DRY_RUN; then
    printf '[dry-run]'; printf ' %q' "$@"; printf '\n'
  else
    "$@"
  fi
}

gh auth status >/dev/null 2>&1 || { echo "gh nao autenticado: rode 'gh auth login'" >&2; exit 1; }
gh api "orgs/$ORG" --jq .login >/dev/null || { echo "Org $ORG nao encontrada" >&2; exit 1; }
mkdir -p "$WORKSPACE"

for item in "${REPOS[@]}"; do
  repo="${item%%|*}"
  descricao="${item#*|}"
  echo "== $ORG/$repo"

  if gh repo view "$ORG/$repo" >/dev/null 2>&1; then
    echo "   ja existe"
  else
    run gh repo create "$ORG/$repo" --public --description "$descricao"
  fi

  # So squash (titulo do PR vira o commit), auto-merge, apaga a branch apos o merge,
  # sem wiki/projects, e secret scanning com push protection (gratis em repo publico).
  run gh repo edit "$ORG/$repo" \
    --description "$descricao" \
    --enable-squash-merge --squash-merge-commit-message pr-title-description \
    --enable-merge-commit=false --enable-rebase-merge=false \
    --enable-auto-merge --delete-branch-on-merge \
    --enable-wiki=false --enable-projects=false \
    --enable-secret-scanning --enable-secret-scanning-push-protection

  destino="$WORKSPACE/$repo"
  if [[ -d "$destino/.git" ]]; then
    echo "   ja clonado em $destino"
  else
    run git clone "https://github.com/$ORG/$repo.git" "$destino"
  fi

  # Clone de repo vazio herda init.defaultBranch (master se nao configurado): forca main.
  if ! $DRY_RUN && ! git -C "$destino" rev-parse --verify -q HEAD >/dev/null; then
    git -C "$destino" symbolic-ref HEAD refs/heads/main
  fi
done

echo
echo "Repositorios na org:"
gh repo list "$ORG" --limit 20 --json name,visibility --jq '.[] | "  \(.name) (\(.visibility))"'
