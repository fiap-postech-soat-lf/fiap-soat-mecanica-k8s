# ADR-F4-10: Observabilidade distribuída no Datadog

- **Status:** Aceito (provado no EKS na janela da F8, 2026-11-10)
- **Data:** 2026-11-09
- **Escopo:** os 4 serviços (outbox e consumidor SQS) e o `-k8s` (collector, `Instrumentation`, dashboards e monitores)
- **Implementação:** `-os`, `-execucao`, `-billing` (`ContextoRastreamento`, `OutboxPublisher*`), os 4 serviços (`SqsConsumidor`, `mensagem.atraso`), `-k8s` (`k8s/collector.yaml`, `k8s/instrumentation.yaml`, `observability/datadog/`, `scripts/datadog-aplicar.sh`, `.github/workflows/datadog.yml`)

## Contexto

A Saga passa por 4 serviços e por filas, e uma falha pode estar em qualquer salto. Sem correlação, cada serviço só mostra o próprio pedaço. A Fase 3 já usava o Datadog por OTLP (ADR-009 do monolito); a Fase 4 precisa de traces entre serviços, logs ligados à OS e alertas sobre a Saga e as filas.

A leitura dos dados da F7 (B0 da F8) mostrou três lacunas:
1. a propagação do agente já atravessa o SQS e o SNS, mas o trace **nasce no `@Scheduled` do outbox**, e não na requisição que criou a mensagem;
2. os logs chegam ao Datadog sem `osId`, `sagaId`, `correlationId` nem `event` (o MDC e os pares chave-valor do SLF4J não são capturados por padrão);
3. as distribuições (`os.tempo_por_situacao`, `http.server.request.duration`) chegam com percentis desligados.

## Decisão

- **Coleta:** agente Java OpenTelemetry (injetado pelo operador, via `Instrumentation`) → collector em DaemonSet → `datadog/exporter` (OTLP, sem Datadog Agent). Tags unificadas `env`, `service` e `version`. Sem a integração CloudWatch, que exige uma IAM role que o Academy não permite.
- **Trace através do outbox (F8-c):** o `traceparent` que a `MensagemFactory` grava no envelope é restaurado como contexto atual durante o `publicar` (`ContextoRastreamento`, nos três outboxes que publicam). O span do SDK (SQS `SendMessage`, SNS `Publish`) passa a ser filho da requisição ou do consumo que criou a mensagem. O consumidor não muda, porque a propagação padrão do agente já funciona; a flag `experimental-use-propagator-for-messaging` não é ligada.
- **O que é "um trace" (F8-d):** vai de uma ação humana até a próxima espera humana. `POST /ordem-servicos` cobre OS, Execução e Identity; `PATCH …/diagnostico/concluir` cobre os 4 serviços. A OS inteira, que dura minutos ou dias, é seguida por `osId`/`sagaId` nos logs e no dashboard da Saga.
- **Identificadores:** o `correlationId` identifica uma **cadeia causal** (uma requisição ou um reenvio por timeout) e muda ao longo da Saga. A chave estável de uma OS é o `osId`/`sagaId`.
- **Logs (F8-f):** o appender OTLP do agente captura o MDC (`sagaId`, `osId`, `correlationId`, `messageId`) e os pares chave-valor (`event`, …) por variáveis do `Instrumentation`. Facets `@osId`, `@sagaId`, `@correlationId` e `@event` no Datadog.
- **Métricas (Micrometer por OTLP):** `saga.{iniciada,concluida,compensada,falhou}{passo}`, `os.tempo_por_situacao{situacao}`, `dlq.depth{fila}`, `webhook.recebido{resultado}`, `mercadopago.erros{operacao}` e a nova `mensagem.atraso{fila,tipo}` (agora − `occurredAt`, medido no `SqsConsumidor` antes do handler, o que inclui o tempo no outbox e na fila). Os percentis das distribuições são ligados por API no `datadog-aplicar.sh`, e `percentiles-histogram` fica ligado nos serviços. Latência e 5xx vêm de `http.server.request.duration`.
- **Dashboards e monitores como código (F8-g):** JSON em `observability/datadog/`, aplicados por `datadog-aplicar.sh` (upsert por título ou nome, nunca apaga) e pelo workflow `datadog.yml`, com `DATADOG_API_KEY` e `DATADOG_APP_KEY` como secrets. Três dashboards (Saga, Mensageria, Operação) e seis monitores (Saga falhou, DLQ, latência p95, 5xx, webhook com assinatura inválida, Mercado Pago com erro).
- **Sem notificação (F8-h):** os monitores não levam `@handle` e `notify_no_data` fica `false`. O estado muda dentro do Datadog, e nenhum e-mail fica num repositório público.

## Alternativas consideradas

| Alternativa | Motivo da rejeição |
|---|---|
| Ligar só a flag de propagação de mensageria do agente | A propagação já funciona; o problema era a raiz do trace no `@Scheduled`, que a flag não resolve |
| Restaurar o contexto no consumidor | O consumidor já continua o trace do produtor (achado 1 da F8); só o publicador do outbox perdia o contexto |
| Datadog Agent lendo o stdout dos pods | Mais um componente por node; os logs já saem por OTLP com o `trace_id` |
| Integração CloudWatch para a idade das mensagens | Exige IAM role, impossível no Academy; `mensagem.atraso` mede o atraso no consumidor |
| Desligar a instrumentação de `@Scheduled` | Não tira o ruído, só troca a raiz dos spans de JDBC e SQS |
| Dashboards criados na interface | Não sobrevivem a uma conta nova (o trial dura 14 dias) |

## Consequências

- Um trace do `concluir` mostra os 4 serviços, e `@osId:<id>` traz os logs de uma OS inteira.
- O `traceparent` do envelope, posto no contrato na F1 "para o caso de a propagação se perder", passa a ser o elo do outbox. Mensagens antigas sem o campo continuam publicáveis (contexto vazio).
- **Limites aceitos:**
  - as varreduras do outbox (1 s), dos timeouts (30 s) e da DLQ (60 s) e o *long polling* do SQS geram traces curtos próprios; a busca filtra por `resource_name`;
  - o Datadog está em **trial de 14 dias** (vence por volta de 2026-11-12); se mudar de conta, `datadog.yml` em modo `aplicar` recria tudo, mas o histórico não é migrado;
  - o `kubectl logs` guarda só os pods atuais, e o Datadog retém traces, logs e métricas por 15 dias no trial;
  - a API de dashboards só aceita as tags `team:` e `ai:`; por isso os dashboards não levam a tag `projeto:`, e os monitores sim;
  - `mercadopago.erros` só existe depois do primeiro erro (é métrica opcional no `--conferir`).

## Evidências (janela da F8, `evidencias/F8/` no repositório de planejamento)

| Decisão | Prova no Datadog |
|---|---|
| Contexto restaurado no outbox | `POST /ordem-servicos` passou de 30 spans, com o trace cortado no `OutboxPublisher.agendado`, para **93 spans** com raiz na requisição, passando por OS, SQS, SNS, Execução e Identity |
| Um trace pelos 4 serviços | `PATCH …/diagnostico/concluir`: **140+ spans** com os, execucao, billing e identity |
| Logs com MDC | `@osId:<id>` traz 30 logs dos 4 serviços; `@event:mensagem_falhou` traz os 5 recebimentos da mensagem envenenada |
| `mensagem.atraso` | p95 por fila no dashboard de Mensageria (≈ 620 ms em `os-saga-respostas` no primeiro ponto) |
| Monitores sem notificação | DLQ em ALERT em ≈ 4–5 min e OK em ≈ 9 min depois do `limpar-dlq`; webhook em ALERT em ≤ 5 min com 5 POSTs sem assinatura |
| Dashboards como código | `datadog.yml` reaplicado 5 vezes pelo mesmo JSON, sem apagar nada |

## Lições da janela

- `sum:` numa *distribution* soma os valores (as durações), e não as ocorrências; para contar, `count:`. Top lists de contadores precisam do agregador `sum`, porque o padrão é a média. Corrigido no PR #31.
- Os percentis das distribuições só existem para amostras posteriores ao `aplicar` que os liga, e a métrica precisa existir antes. Por isso o `aplicar` roda de novo depois da primeira subida com o T01.
- O Datadog descarta a primeira amostra cumulativa de cada série nova ao converter para delta, então a primeira ocorrência de uma série pode faltar nas contagens (ex.: `fim` com 1 em vez de 2).
- A API de dashboards só aceita as tags `team:` e `ai:`.
- **Não validado:** o monitor *Saga falhou* (sem o `--esgotar`; validado só pela amostra da F7 e pelo `--conferir`) e o widget de CPU por serviço (`k8s.pod.cpu.utilization` sem a tag `service`).
