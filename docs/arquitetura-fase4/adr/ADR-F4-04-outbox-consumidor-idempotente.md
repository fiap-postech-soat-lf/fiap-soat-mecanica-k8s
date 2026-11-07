# ADR-F4-04: Transactional Outbox e consumidor idempotente

- **Status:** Aceito
- **Data:** 2026-11-02 (implementado no esqueleto na F1). Revisada em 2026-11-05 (reenvio da Saga e scheduler de timeouts, F4-h e F4-i) em 2026-11-06 (variante DynamoDB, F5-f a F5-i) e em 2026-11-07 (idempotência por chave de negócio em SQL e do webhook, F6-c e F6-i)
- **Escopo:** transversal (Identity, OS e Billing na versão SQL; Execução na versão DynamoDB, F5; ver a RFC-F4-02)
- **Implementação:** `templates/servico-base/.../adapters/out/persistence/mensageria/` (`OutboxSqlAdapter`, `OutboxPublisher`, `ProcessadorMensagemSql`) e `V1__mensageria.sql`; no Execução, `adapters/out/dynamo/` (`TransacaoDynamo`) e `adapters/out/dynamo/mensageria/` (`OutboxDynamoAdapter`, `OutboxPublisherDynamo`, `ProcessadorMensagemDynamo`, `IdempotenciaDynamo`)

## Contexto

Na Saga, cada passo grava uma mudança de estado e envia uma mensagem. Fazer as duas coisas separadamente (*dual write*) quebra nos dois sentidos:

- se a publicação acontece e a transação falha, sai uma mensagem sobre algo que não aconteceu;
- se a transação confirma e a publicação falha, a Saga fica parada.

Do outro lado, SQS padrão entrega **pelo menos uma vez**: duplicatas acontecem em reentregas, timeouts e réplicas do publicador.

## Decisão

**Publicação pela outbox:**

1. O caso de uso chama `OutboxPort.registrar(destino, envelope)` **dentro** da transação de negócio. O adapter usa `Propagation.MANDATORY`, então falha se não houver transação. Ele também valida o nome do destino na hora, para um destino errado quebrar o caso de uso e não só a publicação.
2. O `OutboxPublisher` roda a cada 1 s e trava até 50 pendentes com `SELECT ... FOR UPDATE SKIP LOCKED`, publica cada uma e grava `publicado_em`. Em erro, incrementa `tentativas` e guarda `ultimo_erro`, sem limite de tentativas: quando as credenciais do Academy expiram, as mensagens esperam em vez de serem descartadas.
3. Com várias réplicas, o `SKIP LOCKED` faz cada uma pegar um lote diferente.

A publicação é **at-least-once**: se o pod cair entre publicar e confirmar, a mensagem sai de novo.

**Consumo idempotente:** numa única transação, o `ProcessadorMensagemSql` faz:

- `INSERT INTO mensagem_processada (message_id, tipo) ... ON CONFLICT DO NOTHING`;
- se o insert afetou 0 linhas, a mensagem já foi processada e ele termina sem efeito;
- senão, despacha para o `MensagemHandler` do tipo.

As escritas de negócio e de outbox feitas pelo handler entram na **mesma transação**. Se o handler falha, tudo é desfeito, inclusive o registro de idempotência, e a mensagem volta para a fila. Um tipo sem handler é registrado e concluído (`mensagem_ignorada`).

O `MensagemFactory` preenche `causationId` com o `messageId` da mensagem em processamento e herda o `correlationId`. Assim a cadeia comando → evento → comando fica rastreável.

**Reenvio por timeout da Saga (F4-h):** o reenvio de um comando cria um **envelope novo** (`messageId` novo, mesmo payload, `causationId` = o comando original). Reenviar com o mesmo `messageId` não serve: se a resposta se perdeu, o participante já registrou aquele `messageId` em `mensagem_processada` e descartaria o reenvio como duplicata. Por isso, além do `messageId`, **cada participante é idempotente pela chave de negócio** (`osId` + tipo de comando) e **reemite a resposta** quando recebe de novo um comando que já atendeu. Isso é requisito do Execução (F5) e do Billing (F6).

**`SKIP LOCKED` também nos timeouts (F4-i):** o `SagaTimeoutScheduler` lê as instâncias vencidas (`prazo_em`) com `SELECT ... FOR UPDATE SKIP LOCKED` (até 20 por rodada, em `TransactionTemplate`, como o `OutboxPublisher`) e trata cada uma na mesma transação. Com 2 réplicas do OS, cada uma pega instâncias diferentes e nenhuma instância é tratada duas vezes. O `@Version` da `saga_instancia` cobre o caso restante, o de um handler e o scheduler na mesma Saga.

**Execução (DynamoDB, F5):** mesma semântica, implementada só no `-execucao` (não há segundo serviço DynamoDB, então a variante não volta para o template). Detalhes na [RFC-F4-02](../rfc/RFC-F4-02-modelagem-dynamodb-execucao.md):

- **Transação (F5-f):** a `TransacaoDynamo` acumula as escritas do caso de uso ou do handler (negócio, outbox e idempotência) e grava tudo num único `TransactWriteItems` (até 100 itens). É o equivalente do `@Transactional` + `Propagation.MANDATORY`: o `OutboxDynamoAdapter` exige uma transação ativa.
- **Idempotência por `messageId` (F5-g):** um `Put` condicional (`attribute_not_exists(messageId)`) em `execucao-idempotencia`, com TTL de 7 dias, dentro da mesma transação do handler. `ConditionalCheckFailed` nesse item significa mensagem duplicada e conclui sem efeito. Conflito de versão ou de estoque faz o `ProcessadorMensagemDynamo` repetir o handler até 3 vezes, com nova leitura, e depois devolver a mensagem à fila.
- **Publicador (F5-i):** o `SKIP LOCKED` não existe no DynamoDB. A `execucao-outbox` tem um GSI esparso `pendentes` (atributo `pendente` só enquanto a linha não foi publicada), e o `OutboxPublisherDynamo` (1 s) reserva cada linha com um *lease* condicional (`reservadoAte`, 30 s) antes de publicar. Duas réplicas nunca publicam a mesma linha ao mesmo tempo. Se o pod cai entre publicar e remover `pendente`, o lease vence e a linha sai de novo; a duplicata é absorvida pela idempotência do OS (`mensagem_processada`). As publicadas ganham TTL de 1 dia.
- **Reenvio da Saga (F5-h, requisito da F4-h):** o item da ordem guarda `comandosAtendidos[tipo] = {ids, resposta}`. Como o OS atualiza o `ultimoComando` a cada reenvio, o 2º reenvio traz como `causationId` o 1º reenvio, e não o original. Por isso o Execução guarda uma **cadeia de ids**: um comando cujo `messageId` ou `causationId` está na cadeia é um reenvio, e a resposta guardada é reemitida num envelope novo (`causationId` = o `messageId` recebido), com o id acrescentado à cadeia. Um comando fora da cadeia é uma nova rodada e substitui a entrada. Um `LiberarReservaPecas` sem reserva ativa responde `ReservaPecasLiberada` mesmo assim, porque o OS manda esse comando "por garantia" no timeout da reserva e espera a resposta.

**Billing (SQL, F6-c):** a mesma regra da F5-h, na tabela `comando_atendido` (PK `os_id` + `tipo`, `ids JSONB`, `resposta JSONB`). Antes de aplicar um `GerarOrcamento` ou um `SolicitarPagamento`, o `ParticipanteSaga` consulta a linha: se o `messageId` ou o `causationId` está na cadeia, reemite a resposta guardada num envelope novo (`causationId` = o `messageId` recebido), acrescenta o id à cadeia e **não** refaz o efeito (nem a preferência no Mercado Pago). Um comando fora da cadeia é uma nova rodada e substitui a linha. Tudo na transação do `ProcessadorMensagemSql`. O `OrcamentoFalhou` também fica guardado, para o reenvio reemitir a mesma falha. O `CancelarOrcamento` não tem resposta, então é idempotente pelo estado do orçamento.

**Webhook do Mercado Pago (F6-i):** o Mercado Pago notifica o mesmo pagamento várias vezes (`payment.created`, `payment.updated`) e repete quando não recebe 200. A notificação com assinatura válida é gravada em `webhook_eventos` (200 na hora), e um scheduler (2 s, `FOR UPDATE SKIP LOCKED`) consulta o status no Mercado Pago e aplica o resultado. A chave `(mp_payment_id, status)` é a PK de `mp_status_aplicado`, inserida **na mesma transação** do efeito e da outbox: uma mudança de status vale uma vez, e a repetição conclui sem efeito. É uma segunda camada de idempotência, por chave externa, porque o `messageId` não existe numa notificação HTTP.

## Alternativas consideradas

| Alternativa | Motivo da rejeição |
|---|---|
| Publicar direto após o commit (`@TransactionalEventListener` / *after commit*) | A mensagem se perde se o pod cair entre o commit e a publicação, e não há retry durável |
| CDC com Debezium lendo o WAL | Kafka Connect e mais infraestrutura no Academy para resolver o que uma tabela e um `@Scheduled` resolvem |
| SQS FIFO com deduplicação | A janela de 5 min não cobre reentregas mais tardias, e não resolve o *dual write* |
| Reenviar o comando com o mesmo `messageId` | O participante já o deduplicou, e uma resposta perdida nunca seria refeita |
| Idempotência do webhook só por `payment.id` | Um mesmo pagamento passa por mais de um status (`pending` → `approved`), e cada mudança deve valer uma vez |
| Idempotência "natural" de cada handler | Depende de cada caso de uso acertar; o registro por `messageId` dá a garantia uma vez, no esqueleto |

## Consequências

**Positivas**
- Nenhuma mensagem sai de uma transação desfeita, e nenhuma transação confirmada fica sem a sua mensagem.
- **Testes nos ITs do esqueleto:**
  - **`OutboxPublisherIT`:** rollback não publica, a linha travada por uma réplica não é vista pela outra, e uma falha incrementa `tentativas`;
  - **`ProcessadorMensagemSqlIT`:** a mesma mensagem entregue 2× executa o handler 1×, e uma falha no handler desfaz a outbox e a idempotência;
  - **resposta herdada:** a resposta criada pelo handler herda o contexto e chega à fila assinante.

**Negativas / riscos**
- **Latência:** até ~1 s a mais por mensagem (intervalo do publicador), e duas tabelas a mais por serviço SQL (`V1__mensageria.sql`).
- **Crescimento:** `mensagem_processada` cresce sem limpeza; uma rotina de expurgo fica para depois da F9, se o volume justificar.
- **Destino quebrado:** uma linha com destino inválido é tentada a cada segundo indefinidamente. O alerta vem do log `outbox_publicacao_falhou`.
- **Variante DynamoDB (F5):** o GSI é eventualmente consistente, então a publicação pode atrasar ~1 s além do intervalo. A condição do lease é avaliada na tabela base, e por isso uma linha que o GSI ainda mostra, mas já foi publicada, é descartada sem republicar. Os testes (`OutboxPublisherDynamoIT`, `ProcessadorMensagemDynamoIT`, `TransacaoDynamoIT`, `ParticipanteSagaTest`) cobrem rollback, duplicata, conflito e as três formas de reenvio.
