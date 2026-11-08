#!/usr/bin/env bash
# Sobe o ambiente da Fase 4 do zero, na ordem da secao 9.2 do plano da F2 (B4):
#   0) atualizar-credenciais.sh   1) workflow Cluster do -k8s
#   2) CD de identity, execucao, billing e os (so quem tem infra/*.tf na main)
#   3) CD do -auth (API Gateway + authorizer)   4) smoke-borda.sh
#   5) E2E: dispara o e2e.yml do -os (F7-d). ESCREVE DADOS: cria 3 OS com dados proprios. Com a borda no
#      ar, e a prova padrao de que o ambiente subiu inteiro (o CD do -os, que roda antes do -auth, pula o E2E)
# Cada workflow e disparado com o gh ja autenticado e acompanhado ate o fim (sem PAT).
# No fim imprime a URL da API e o tempo de cada etapa (dado da RFC-F4-03).
#
# Uso: scripts/subir-ambiente.sh [--dry-run] [--sem-e2e]
#   --dry-run: mostra a ordem e o que seria disparado, sem disparar nada
#   --sem-e2e: nao dispara o e2e.yml no fim
# Variaveis: ORG (padrao fiap-postech-soat-lf), AWS_REGION (padrao us-east-1)
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ORG="${ORG:-fiap-postech-soat-lf}"
# O perfil local pode nao ter regiao: sem isto, o resumo final sai sem a URL da API (NoRegion).
export AWS_DEFAULT_REGION="${AWS_REGION:-us-east-1}"
DRY_RUN=false
SEM_E2E=false

for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=true ;;
    --sem-e2e) SEM_E2E=true ;;
    -h|--help) sed -n '2,/^set -euo/p' "$0" | grep '^#' | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Argumento desconhecido: $arg" >&2; exit 1 ;;
  esac
done

# shellcheck source=scripts/lib-workflows.sh
source "$DIR/lib-workflows.sh"

# Ordem B4 (F4-a): o identity primeiro (dono das chaves do JWT e da fila de notificacoes), depois
# execucao e billing (donos dos topicos e das filas de comando) e o os por ultimo, que le o SSM dos
# tres e cria as assinaturas. Ordem antiga: o os subia sem a chave publica e recusava todos os tokens.
SERVICOS=(identity execucao billing os)
TEMPOS=()

# cronometrar <etapa> <comando...>: roda o comando e guarda a duracao no resumo.
cronometrar() {
  local etapa="$1" inicio=$SECONDS rc=0
  shift
  "$@" || rc=$?
  TEMPOS+=("$(printf '%-28s %s' "$etapa" "$(formatar_duracao $((SECONDS - inicio)))")")
  return "$rc"
}

# tem_infra <repo>: a main tem pelo menos um infra/*.tf.
tem_infra() {
  local n
  n=$(gh api "repos/$ORG/$1/contents/infra?ref=main" \
    --jq '[.[] | select(.type == "file" and (.name | endswith(".tf")))] | length' 2> /dev/null) || n=0
  [[ "$n" -gt 0 ]]
}

# tem_arquivo <repo> <caminho>: o arquivo existe na main.
tem_arquivo() {
  gh api "repos/$ORG/$1/contents/$2?ref=main" --silent 2> /dev/null
}

gh auth status > /dev/null 2>&1 || { echo "gh nao autenticado: rode 'gh auth login'" >&2; exit 1; }
inicio_total=$SECONDS

echo "== 0) Credenciais do Academy nos secrets da org"
if $DRY_RUN; then
  "$DIR/atualizar-credenciais.sh" --dry-run
else
  "$DIR/atualizar-credenciais.sh"
fi

echo
echo "== 1) Cluster: fiap-soat-mecanica-k8s / cluster.yml"
cronometrar "cluster.yml" disparar_e_esperar fiap-soat-mecanica-k8s cluster.yml

echo
echo "== 2) Servicos (ordem: ${SERVICOS[*]})"
for svc in "${SERVICOS[@]}"; do
  repo="fiap-soat-mecanica-$svc"
  if tem_infra "$repo"; then
    echo " - $repo: cd.yml"
    cronometrar "cd.yml ($svc)" disparar_e_esperar "$repo" cd.yml
  else
    echo " - $repo: sem infra/*.tf na main, pulado"
  fi
done

echo
echo "== 3) Borda: fiap-soat-mecanica-auth / cd.yml"
borda=false
if tem_infra fiap-soat-mecanica-auth && tem_arquivo fiap-soat-mecanica-auth .github/workflows/cd.yml; then
  cronometrar "cd.yml (auth)" disparar_e_esperar fiap-soat-mecanica-auth cd.yml
  borda=true
else
  echo " - fiap-soat-mecanica-auth: sem infra/*.tf ou sem cd.yml na main, pulado"
fi

echo
echo "== 4) Smoke da borda"
smoke_ok=true
if $DRY_RUN; then
  echo "   [dry-run] scripts/smoke-borda.sh"
elif $borda; then
  cronometrar "smoke-borda.sh" "$DIR/smoke-borda.sh" || smoke_ok=false
else
  echo "   pulado (sem borda)"
fi

echo
echo "== 5) E2E: fiap-soat-mecanica-os / e2e.yml"
e2e_ok=true
E2E_LINHA=""
if $SEM_E2E; then
  echo "   pulado (--sem-e2e)"
elif $DRY_RUN; then
  echo "   [dry-run] gh workflow run e2e.yml -R $ORG/fiap-soat-mecanica-os"
elif $borda && $smoke_ok; then
  cronometrar "e2e.yml (os)" disparar_e_esperar fiap-soat-mecanica-os e2e.yml || e2e_ok=false
  E2E_LINHA=$(gh run list -R "$ORG/fiap-soat-mecanica-os" --workflow e2e.yml --event workflow_dispatch --limit 1 \
    --json conclusion,url --jq '.[0] | "\(.conclusion): \(.url)"' 2> /dev/null) || E2E_LINHA="(run nao encontrado)"
else
  echo "   pulado (sem borda ou com o smoke falho)"
fi

echo
echo "== 6) Resumo"
if ! $DRY_RUN && $borda; then
  echo "API: $(aws ssm get-parameter --name /mecanica/auth/api-url --query Parameter.Value --output text)"
fi
for linha in "${TEMPOS[@]}"; do
  echo "   $linha"
done
echo "   $(printf '%-28s %s' "total" "$(formatar_duracao $((SECONDS - inicio_total)))")"
[[ -z "$E2E_LINHA" ]] || echo "   E2E: $E2E_LINHA"

if ! $smoke_ok; then
  echo "Smoke da borda com falhas (ver acima)." >&2
  exit 1
fi
if ! $e2e_ok; then
  echo "E2E com falhas (ver o run acima); nada foi desfeito." >&2
  exit 1
fi
