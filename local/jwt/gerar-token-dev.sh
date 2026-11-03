#!/usr/bin/env bash
# Imprime um JWT RS256 de 1 h no formato do Identity (contrato jwt.md / secao 7.5 do plano da F1),
# assinado com a chave de dev. Uso nos testes manuais: curl -H "Authorization: Bearer $(...)".
#
# Uso: local/jwt/gerar-token-dev.sh <CLIENTE|ATENDENTE|MECANICO|ALMOXARIFE> [sub]
#   sub: UUID do cliente ou funcionario (padrao: um UUID aleatorio)
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PRIVADA="$DIR/dev-private.pem"

uso() { echo "Uso: $0 <CLIENTE|ATENDENTE|MECANICO|ALMOXARIFE> [sub]" >&2; exit 1; }
[[ $# -ge 1 && $# -le 2 ]] || uso
case "$1" in
  CLIENTE) TIPO=CLIENTE; CARGO="" ;;
  ATENDENTE | MECANICO | ALMOXARIFE) TIPO=FUNCIONARIO; CARGO="$1" ;;
  *) uso ;;
esac
uuid() { cat /proc/sys/kernel/random/uuid 2> /dev/null || uuidgen | tr '[:upper:]' '[:lower:]'; }
SUB="${2:-$(uuid)}"
[[ "$SUB" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]] || { echo "sub precisa ser um UUID: $SUB" >&2; exit 1; }
[[ -f "$PRIVADA" ]] || { echo "Chave de dev ausente: rode $DIR/gerar-chaves-dev.sh" >&2; exit 1; }

b64url() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }

agora=$(date +%s)
header=$(printf '%s' '{"alg":"RS256","typ":"JWT","kid":"mecanica-identity-v1"}' | b64url)
payload=$(jq -nc \
  --arg sub "$SUB" --arg tipo "$TIPO" --arg cargo "$CARGO" --arg jti "$(uuid)" --argjson iat "$agora" \
  '{iss: "fiap-soat-mecanica-identity", aud: "fiap-soat-mecanica", sub: $sub, principal_type: $tipo}
   + (if $cargo == "" then {} else {cargo: $cargo} end)
   + {iat: $iat, exp: ($iat + 3600), jti: $jti}' | b64url)
assinatura=$(printf '%s.%s' "$header" "$payload" | openssl dgst -sha256 -sign "$PRIVADA" -binary | b64url)
echo "$header.$payload.$assinatura"
