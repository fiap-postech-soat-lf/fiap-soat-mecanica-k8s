#!/usr/bin/env bash
# Destroi um stack Terraform guardado no backend S3 da conta (bucket mecanica-tfstate-<conta>).
# Idempotente: state vazio (ja destruido ou nunca aplicado) e pulado sem erro.
# Chamado pelo workflow destruir-ambiente.yml; serve tambem para destruir um stack a mao.
#
# Uso: scripts/destruir-stack.sh [--dry-run] <diretorio-terraform> <key-do-state>
#   ex.: scripts/destruir-stack.sh terraform fiap-soat-mecanica-k8s/terraform.tfstate
#   --dry-run: so mostra o plano de destroy (sem lock no state)
# Variaveis: AWS_REGION (padrao us-east-1)
set -euo pipefail

REGIAO="${AWS_REGION:-us-east-1}"
DRY_RUN=false
posicionais=()

for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=true ;;
    -h|--help) sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*) echo "Argumento desconhecido: $arg" >&2; exit 1 ;;
    *) posicionais+=("$arg") ;;
  esac
done
[[ ${#posicionais[@]} -eq 2 ]] || { echo "Uso: $0 [--dry-run] <diretorio-terraform> <key-do-state>" >&2; exit 1; }
dir="${posicionais[0]}"
key="${posicionais[1]}"
[[ -d "$dir" ]] || { echo "Diretorio nao existe: $dir" >&2; exit 1; }

conta=$(aws sts get-caller-identity --query Account --output text)
terraform -chdir="$dir" init -input=false -reconfigure \
  -backend-config="bucket=mecanica-tfstate-${conta}" \
  -backend-config="key=${key}" \
  -backend-config="region=${REGIAO}" \
  -backend-config="use_lockfile=true"

# Sem state, o "state list" sai com erro. So esse caso conta como vazio: qualquer outro
# erro (credencial, permissao) precisa falhar, e nao pular o destroy em silencio.
erro=$(mktemp)
trap 'rm -f "$erro"' EXIT
if ! recursos=$(terraform -chdir="$dir" state list 2> "$erro"); then
  if grep -q 'No state file was found' "$erro"; then
    recursos=""
  else
    cat "$erro" >&2
    exit 1
  fi
fi
if [[ -z "$recursos" ]]; then
  echo "State vazio em $key: nada a destruir."
  exit 0
fi

if $DRY_RUN; then
  terraform -chdir="$dir" plan -destroy -input=false -lock=false
else
  terraform -chdir="$dir" destroy -input=false -auto-approve
fi
