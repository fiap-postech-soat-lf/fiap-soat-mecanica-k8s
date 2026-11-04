#!/usr/bin/env bash
# Funcoes comuns do subir-ambiente.sh e do destruir-ambiente.sh (carregado com source).
# Quem carrega define ORG e DRY_RUN (true|false).

: "${ORG:?ORG nao definida}"
: "${DRY_RUN:?DRY_RUN nao definida}"

# disparar_e_esperar <repo> <workflow> [-f chave=valor ...]
# Dispara o workflow na main com o gh ja autenticado (sem PAT), acha o run criado pelo
# disparo e acompanha ate o fim. Retorna 1 se o run nao terminar verde.
disparar_e_esperar() {
  local repo="$1" workflow="$2"
  shift 2
  if [[ "$DRY_RUN" == true ]]; then
    echo "   [dry-run] gh workflow run $workflow -R $ORG/$repo --ref main $*"
    return 0
  fi

  # Ids dos runs anteriores: o run novo e o primeiro id fora desta lista.
  local anteriores id="" _
  anteriores=$(gh run list -R "$ORG/$repo" --workflow "$workflow" --event workflow_dispatch \
    --limit 50 --json databaseId --jq '[.[].databaseId]')
  gh workflow run "$workflow" -R "$ORG/$repo" --ref main "$@"

  for _ in $(seq 1 30); do
    sleep 4
    id=$(gh run list -R "$ORG/$repo" --workflow "$workflow" --event workflow_dispatch \
        --limit 50 --json databaseId,createdAt \
      | jq -r --argjson anteriores "$anteriores" \
        '[.[] | select(.databaseId as $i | $anteriores | index($i) | not)]
         | sort_by(.createdAt) | .[0].databaseId // empty')
    [[ -n "$id" ]] && break
  done
  if [[ -z "$id" ]]; then
    echo "Run de $workflow em $ORG/$repo nao apareceu em 2 min." >&2
    return 1
  fi

  local url="https://github.com/$ORG/$repo/actions/runs/$id"
  echo "   run: $url"
  if ! gh run watch "$id" -R "$ORG/$repo" --exit-status --compact --interval 20 > /dev/null; then
    echo "   FALHOU: $url" >&2
    return 1
  fi
  echo "   concluido com sucesso"
}

# formatar_duracao <segundos> -> "12m05s"
formatar_duracao() {
  printf '%dm%02ds' "$(($1 / 60))" "$(($1 % 60))"
}
