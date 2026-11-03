#!/usr/bin/env bash
# Gera o par RSA 2048 de desenvolvimento (dev-private.pem / dev-public.pem, ignorados pelo git).
# A chave publica e lida pelos servicos no perfil local (app.security.jwt.public-key=file:...);
# a privada assina os tokens do gerar-token-dev.sh. Nao gera de novo se o par ja existir.
#
# Uso: local/jwt/gerar-chaves-dev.sh [--forcar]
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PRIVADA="$DIR/dev-private.pem"
PUBLICA="$DIR/dev-public.pem"

case "${1:-}" in
  "") FORCAR=false ;;
  --forcar) FORCAR=true ;;
  *) echo "Uso: $0 [--forcar]" >&2; exit 1 ;;
esac

if [[ -f "$PRIVADA" && -f "$PUBLICA" ]] && ! $FORCAR; then
  echo "Par de dev ja existe em $DIR (use --forcar para gerar outro; tokens antigos deixam de valer)"
  exit 0
fi

(umask 077 && openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "$PRIVADA" 2> /dev/null)
openssl pkey -in "$PRIVADA" -pubout -out "$PUBLICA"
echo "Gerados $PRIVADA e $PUBLICA"
