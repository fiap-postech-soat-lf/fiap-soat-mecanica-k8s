#!/usr/bin/env bash
# Compara um servico ja gerado com o que o template geraria hoje (T12 do plano da F1).
# Serve para propagar correcoes feitas no template: gera o servico num diretorio temporario
# (sem verify) e roda diff -ru so nas partes que vem do esqueleto.
#
# Uso: scripts/comparar-esqueleto.sh <identity|os|billing|execucao> [--destino DIR]
#   --destino  pasta onde esta fiap-soat-mecanica-<svc> (padrao $WORKSPACE ou /home/rede/git/fase4)
# Saida 0: sem diferencas; 1: ha diferencas (o diff e impresso).
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DESTINO_BASE="${WORKSPACE:-/home/rede/git/fase4}"
SVC=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --destino) [[ $# -ge 2 ]] || { echo "--destino precisa de um valor" >&2; exit 2; }; DESTINO_BASE="$2"; shift 2 ;;
    -*) echo "Opcao desconhecida: $1" >&2; exit 2 ;;
    *) SVC="$1"; shift ;;
  esac
done
case "$SVC" in
  identity | os | billing) MODO=sql ;;
  execucao) MODO=dynamo ;;
  *) echo "Uso: $0 <identity|os|billing|execucao> [--destino DIR]" >&2; exit 2 ;;
esac

REAL="$DESTINO_BASE/fiap-soat-mecanica-$SVC"
[[ -d "$REAL" ]] || { echo "Servico nao encontrado em $REAL" >&2; exit 2; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
"$DIR/novo-servico.sh" "$SVC" "$MODO" --destino "$TMP" --sem-verify > /dev/null
GERADO="$TMP/fiap-soat-mecanica-$SVC"

PACOTE="br/com/fiap/soat/mecanica/$SVC"
CAMINHOS=(
  "src/main/java/$PACOTE/config"
  "src/main/java/$PACOTE/application/mensageria"
  "src/main/java/$PACOTE/adapters/in/messaging"
  "src/main/java/$PACOTE/adapters/in/web/security"
  "src/main/java/$PACOTE/adapters/out/messaging"
  "src/main/java/$PACOTE/adapters/out/persistence/mensageria"
  "src/test/java/$PACOTE/support"
  "k8s"
  ".github"
  "Dockerfile"
)

diferente=false
for caminho in "${CAMINHOS[@]}"; do
  [[ -e "$GERADO/$caminho" || -e "$REAL/$caminho" ]] || continue
  if ! diff -ru "$GERADO/$caminho" "$REAL/$caminho" > "$TMP/diff.txt" 2>&1; then
    diferente=true
    sed "s#$GERADO#template#g; s#$REAL#$SVC#g" "$TMP/diff.txt"
  fi
done

if $diferente; then
  echo "== fiap-soat-mecanica-$SVC diverge do template nos trechos acima" >&2
  exit 1
fi
echo "== fiap-soat-mecanica-$SVC igual ao template nas partes comuns"
