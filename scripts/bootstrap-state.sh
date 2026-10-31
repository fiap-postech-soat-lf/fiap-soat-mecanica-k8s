#!/usr/bin/env bash
# Cria e configura o bucket S3 de state do Terraform na conta AWS ativa (um por conta,
# compartilhado pelos 7 repos). Idempotente: pode rodar de novo, so reaplica a configuracao.
# Adaptado de fiap-soat-mecanica-api-k8s/bootstrap/create-state-bucket.sh (Fase 3).
#
# Uso: scripts/bootstrap-state.sh [--dry-run]
# Variaveis: AWS_REGION (padrao us-east-1), AWS_PROFILE (padrao do AWS CLI)
set -euo pipefail

REGION="${AWS_REGION:-us-east-1}"
DRY_RUN=false
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=true

run() {
  if $DRY_RUN; then
    printf '[dry-run]'; printf ' %q' "$@"; printf '\n'
  else
    "$@"
  fi
}

ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text 2>/dev/null)" \
  || { echo "Credenciais AWS invalidas ou expiradas: reinicie o Learner Lab e copie o bloco de novo" >&2; exit 1; }
BUCKET="mecanica-tfstate-${ACCOUNT_ID}"
echo "== Bucket $BUCKET (conta $ACCOUNT_ID, $REGION)"

if aws s3api head-bucket --bucket "$BUCKET" 2>/dev/null; then
  echo "   ja existe"
else
  if [[ "$REGION" == "us-east-1" ]]; then
    run aws s3api create-bucket --bucket "$BUCKET" --region "$REGION"
  else
    run aws s3api create-bucket --bucket "$BUCKET" --region "$REGION" \
      --create-bucket-configuration LocationConstraint="$REGION"
  fi
  if ! $DRY_RUN; then
    aws s3api wait bucket-exists --bucket "$BUCKET"
    echo "   criado"
  fi
fi

run aws s3api put-bucket-versioning --bucket "$BUCKET" \
  --versioning-configuration Status=Enabled

run aws s3api put-public-access-block --bucket "$BUCKET" \
  --public-access-block-configuration \
  BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true

run aws s3api put-bucket-encryption --bucket "$BUCKET" \
  --server-side-encryption-configuration \
  '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'

# Versoes antigas do state (e dos .tflock do use_lockfile) expiram apos 30 dias.
run aws s3api put-bucket-lifecycle-configuration --bucket "$BUCKET" \
  --lifecycle-configuration \
  '{"Rules":[{"ID":"expira-versoes-antigas","Status":"Enabled","Filter":{},"NoncurrentVersionExpiration":{"NoncurrentDays":30}}]}'

$DRY_RUN && exit 0

echo "   versionamento: $(aws s3api get-bucket-versioning --bucket "$BUCKET" --query Status --output text)"

cat <<EOF

Bucket pronto. Cada repo guarda o state na key <nome-do-repo>/terraform.tfstate
(ex.: fiap-soat-mecanica-identity/terraform.tfstate). O backend.tf so tem
'backend "s3" {}'; os workflows (e o init local) passam o resto assim:

terraform init \\
  -backend-config="bucket=mecanica-tfstate-\$(aws sts get-caller-identity --query Account --output text)" \\
  -backend-config="key=<nome-do-repo>/terraform.tfstate" \\
  -backend-config="region=${REGION}" \\
  -backend-config="use_lockfile=true"
EOF
