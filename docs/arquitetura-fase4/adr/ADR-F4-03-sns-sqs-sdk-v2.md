# ADR-F4-03: SNS + SQS com AWS SDK v2 direto

- **Status:** Aceito
- **Data:** 2026-11-02 (decidido no planejamento; o uso do SDK direto é a decisão F1-c)
- **Escopo:** transversal (os 4 serviços)
- **Implementação:** `templates/servico-base/` (`SqsConsumidor`, `SnsSqsPublicador`, `DestinosMensageria`, `DlqDepthMetrics`), `local/localstack/init/ready.d/01-mensageria.sh`; contratos em `docs/contratos/`

## Contexto

A Saga (ADR-F4-02) e a notificação do cliente precisam de mensageria assíncrona entre os serviços. A plataforma é a AWS Academy. Kafka/MSK e brokers no cluster custam caro ou exigem operação, enquanto SNS e SQS são gerenciados e baratos. O ambiente local e os testes precisam reproduzir a mesma topologia sem AWS.

Também era preciso escolher o cliente Java. O plano original previa validar o Spring Cloud AWS 3.x, que traz `@SqsListener` e `SnsTemplate`.

## Decisão

**Topologia** (nomes iguais no Terraform e no LocalStack; tabela 2.4 de `docs/contratos/convencoes.md`):

- **Comandos** vão para a **fila do consumidor**: `mecanica-execucao-comandos` e `mecanica-billing-comandos`.
- **Eventos** vão para o **tópico do produtor**: `mecanica-execucao-eventos`, `mecanica-billing-eventos` e `mecanica-os-eventos`. Cada tópico é assinado pela fila de quem consome: `mecanica-os-saga-respostas` e `mecanica-identity-notificacoes`.
- **Assinaturas** com `RawMessageDelivery=true`: o corpo na fila é o próprio envelope, sem o embrulho do SNS, e os atributos de mensagem (`type`) chegam na fila.
- **Filas:** padrão (não FIFO), com `VisibilityTimeout=30`, retenção de 4 dias e DLQ com `maxReceiveCount=5`.
- **Envelope comum** (`envelope.schema.json`): carrega `messageId`, `correlationId`, `causationId` e o `traceparent` W3C opcional. Assim o trace pode ser restaurado mesmo se a propagação automática se perder no SNS → SQS.

**Cliente: AWS SDK v2 direto** (`SnsClient`, `SqsClient`), **sem Spring Cloud AWS**:

- **`SqsConsumidor`:** poller próprio, com uma virtual thread por fila e ciclo de vida pelo `SmartLifecycle`. Faz long polling (`waitTimeSeconds=20`, até 10 mensagens) e só chama `DeleteMessage` depois do processamento com sucesso. Exceção ou JSON inválido deixam a mensagem voltar, e no 5º recebimento ela vai para a DLQ.
- **`SnsSqsPublicador`:** resolve o nome lógico em `app.messaging.destinos.<nome>`. Se o destino é ARN de tópico, publica no SNS; se é URL de fila, envia direto ao SQS. Nos dois casos envia o atributo `type`.
- **`DlqDepthMetrics`:** a cada 60 s publica o gauge `dlq.depth{fila}`, base do alerta no Datadog.

## Alternativas consideradas

| Alternativa | Motivo da rejeição |
|---|---|
| Spring Cloud AWS 3.x (`@SqsListener`, `SnsTemplate`) | Mais uma árvore de dependências, com risco de compatibilidade a cada versão do Boot 3.5. A confirmação e o descarte das mensagens ficam escondidos na anotação, quando é exatamente o que a Saga precisa controlar: não apagar em falha e deixar a DLQ agir |
| Amazon MSK / Kafka | Caro e lento de subir no Academy; a ordem por partição não é necessária, porque a Saga trata a ordem pelo passo atual |
| RabbitMQ no cluster | Mais um componente com estado para operar no EKS, que fica desligado entre as janelas de integração |
| EventBridge | Roteamento por regra é útil, mas não substitui a fila com DLQ e visibility timeout no consumo. Também não é necessário para 3 tópicos fixos |
| Filas FIFO | A deduplicação de 5 min não substitui a idempotência (ADR-F4-04), e o throughput é menor. A Saga não depende de ordem global |

## Consequências

**Positivas**
- **Comportamento explícito:** `DeleteMessage` só depois do sucesso, e a DLQ é a última defesa, visível no gauge. Os testes provam isso (`SqsConsumidorIT`).
- **Testes sem AWS:** os ITs usam LocalStack 4.14.0 (Testcontainers), e o `local/verificar.sh` prova a entrega raw SNS → SQS no compose.
- **Menos dependências:** só os módulos `sns` e `sqs` do SDK (BOM 2.56.0). Saiu do plano o spike de validação do Spring Cloud AWS.

**Negativas / riscos**
- **Código próprio de infraestrutura:** poller, shutdown e pausa após erro são código nosso e precisam de teste. Isso foi coberto no esqueleto, com a manutenção concentrada no template.
- **Destinos por variável explícita:** cada destino precisa de uma variável própria (`MESSAGING_DESTINO_<NOME>`), porque a ligação relaxada do Spring não preserva o `-` das chaves de mapa vindas de variáveis de ambiente.
- **Long polling no shutdown:** pode atrasar o encerramento do pod em até ~25 s.
