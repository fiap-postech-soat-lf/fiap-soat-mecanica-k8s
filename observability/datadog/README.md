# Datadog como código (F8)

Dashboards e monitores da Fase 4, versionados aqui e aplicados por `scripts/datadog-aplicar.sh` ou pelo workflow
`datadog` (`workflow_dispatch`, entrada `modo` = `conferir` | `aplicar`). Nada disso depende do EKS: o
`destruir-ambiente` não apaga nada daqui, e uma conta nova do Datadog recebe tudo com um `aplicar`.

## O que cada item mostra

| Item | Arquivo | Mostra |
|---|---|---|
| Dashboard **Mecânica — Saga** | `dashboards/saga.json` | Saga iniciada, concluída, compensada e falhou por dia e por `passo`; duração por situação (p50, p95); estado dos monitores; logs de `resposta_fora_do_passo`, `comando_reemitido` e `mensagem_duplicada` |
| Dashboard **Mecânica — Mensageria** | `dashboards/mensageria.json` | `dlq.depth` por fila; `mensagem.atraso` p95 por fila; consumo por fila e tipo; `mensagem_falhou` e `outbox_publicacao_falhou` por serviço |
| Dashboard **Mecânica — Operação** | `dashboards/operacao.json` | Volume de OS, tempo médio por situação, erros do Mercado Pago e do webhook, 5xx, latência p95, memória e CPU |
| Monitor **Saga falhou** | `monitors/saga-falhou.json` | `saga.falhou` > 0 em 5 min |
| Monitor **DLQ com mensagens** | `monitors/dlq-depth.json` | `dlq.depth` > 0, um alerta por `fila` |
| Monitor **Latência p95 alta** | `monitors/latencia-p95.json` | p95 de `http.server.request.duration` > 1 s, por `service` |
| Monitor **Erros 5xx** | `monitors/erros-5xx.json` | mais de 2% de 5xx em 10 min, por `service` |
| Monitor **Webhook com assinatura inválida** | `monitors/webhook-assinatura-invalida.json` | mais de 3 em 10 min (o `smoke-borda.sh` manda 1 por subida) |
| Monitor **Mercado Pago com erro** | `monitors/mercadopago-erros.json` | `mercadopago.erros` > 0 em 10 min |

O **Service Map** é a tela nativa do APM (*APM → Service Map*, `env:prd`) e não tem JSON.
Todo título começa com "Mecânica —"; os monitores têm a tag `projeto:mecanica-fase4` (a API de dashboards só aceita as tags `team:` e `ai:`). É o título (dashboard) ou o nome (monitor) que
o script usa como chave do upsert. **Os monitores não notificam ninguém** (sem `@handle`, `notify_no_data: false`): só
mudam de estado no Datadog.

## Arquivos de apoio

- `metricas.txt`: métricas que os JSON usam. O `--conferir` falha se uma obrigatória não existir; as com `?` só avisam.
- `percentis.json`: distribuições cujos **percentis o script liga** por API (`POST/PATCH /api/v2/metrics/<nome>/tags`, com a
  lista de tags consultáveis). No Datadog elas nascem com *Percentiles: OFF*, e as consultas `p95:` dependem disso
  (achado D5 do B0). `mensagem.atraso` só existe depois da primeira subida com o T01 no ar: rode `aplicar` de novo depois.

## Como aplicar

```bash
gh workflow run datadog.yml -R fiap-postech-soat-lf/fiap-soat-mecanica-k8s -f modo=conferir   # só valida
gh workflow run datadog.yml -R fiap-postech-soat-lf/fiap-soat-mecanica-k8s -f modo=aplicar    # valida e faz o upsert
```

Localmente: `DATADOG_API_KEY=… DATADOG_APP_KEY=… scripts/datadog-aplicar.sh [--conferir | --dry-run]`. O script **nunca apaga**.
Se um dashboard ou monitor sair do repositório, apague-o à mão no Datadog.

## Conta nova

Uma conta sem métricas (trial novo) recebe tudo em **dois tempos**:

1. Com o EKS desligado: `gh workflow run datadog.yml -R fiap-postech-soat-lf/fiap-soat-mecanica-k8s -f modo=aplicar -f conta_nova=true`
   (ou `scripts/datadog-aplicar.sh --conta-nova`). Métrica obrigatória ausente vira aviso, e os 3 dashboards e 6 monitores são criados.
2. Depois da subida e do 1º E2E: `-f modo=aplicar` sem `conta_nova`. Agora as métricas existem, e os percentis são ligados.
   Um 2º E2E gera as amostras de p95.

As facets `@osId`, `@sagaId`, `@correlationId` e `@event` são recriadas à mão (*Logs → Add facet*) depois dos primeiros logs.
Troca de chaves: `scripts/atualizar-credenciais.sh --fixos`.

## Chaves

- `DATADOG_API_KEY`: secret da org (também usado pelo collector).
- `DATADOG_APP_KEY`: secret da org visível **só** para o `-k8s`. Gravar com `scripts/atualizar-credenciais.sh --fixos`.
  Escopos da Application Key: `dashboards_read`, `dashboards_write`, `monitors_read`, `monitors_write`, `metrics_read` e a
  escrita de configuração de tags de métricas (para os percentis).

Nenhuma chave vai para arquivo, log ou argumento de comando.

## Unidades e limites conhecidos

- `http.server.request.duration` está em **segundos** (limiar do monitor = 1). Conferir a unidade de `mensagem.atraso` e de
  `os.tempo_por_situacao` na primeira janela: o `micrometer-registry-otlp` exporta em milissegundos por padrão, e os
  títulos dos widgets não afirmam a unidade.
- Os `@Scheduled` do outbox, do timeout e da DLQ, e o *long polling* do SQS, geram traces curtos próprios; filtre a busca de
  traces pela operação HTTP ou pelo `resource_name`.
- As facets `@osId`, `@sagaId`, `@correlationId` e `@event` precisam ser criadas à mão no Datadog (*Logs → Add facet*) na
  primeira vez; os atributos chegam pelo `instrumentation.yaml` (captura do MDC).
