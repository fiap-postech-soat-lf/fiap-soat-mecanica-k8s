#!/usr/bin/env bash
# Destroi o ambiente inteiro: dispara o workflow destruir-ambiente.yml do -k8s (que roda os
# terraform destroy na ordem inversa da B4, no GitHub, porque leva ~20 min), espera o fim e
# confere os orfaos localmente com verificar-orfaos.sh.
#
# Uso: scripts/destruir-ambiente.sh [--dry-run]
#   --dry-run: so mostra o disparo; a verificacao de orfaos (so leitura) roda assim mesmo
# Variaveis: ORG (padrao fiap-postech-soat-lf)
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ORG="${ORG:-fiap-postech-soat-lf}"
DRY_RUN=false

for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=true ;;
    -h|--help) sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Argumento desconhecido: $arg" >&2; exit 1 ;;
  esac
done

# shellcheck source=scripts/lib-workflows.sh
source "$DIR/lib-workflows.sh"

gh auth status > /dev/null 2>&1 || { echo "gh nao autenticado: rode 'gh auth login'" >&2; exit 1; }
inicio=$SECONDS

echo "== 0) Credenciais do Academy nos secrets da org"
if $DRY_RUN; then
  "$DIR/atualizar-credenciais.sh" --dry-run
else
  "$DIR/atualizar-credenciais.sh"
fi

echo
echo "== 1) fiap-soat-mecanica-k8s / destruir-ambiente.yml"
disparar_e_esperar fiap-soat-mecanica-k8s destruir-ambiente.yml -f confirmacao=destruir
echo "   duracao: $(formatar_duracao $((SECONDS - inicio)))"

echo
echo "== 2) Orfaos"
"$DIR/verificar-orfaos.sh"
