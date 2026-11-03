# ADR-F4-04: Transactional Outbox e consumidor idempotente

- **Status:** Aceito
- **Data:** 2026-11-02 (implementado no esqueleto na F1)
- **Escopo:** transversal (Identity, OS e Billing na versão SQL; Execução na versão DynamoDB, F5)
- **Implementação:** `templates/servico-base/.../adapters/out/persistence/mensageria/` (`OutboxSqlAdapter`, `OutboxPublisher`, `ProcessadorMensagemSql`) e `V1__mensageria.sql`

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

**Execução (DynamoDB, F5):** mesma semântica com as tabelas `execucao-outbox` e `execucao-idempotencia`. A idempotência usa `PutItem` condicional com TTL, e a reserva de estoque usa `TransactWriteItems` (RFC-F4-02).

## Alternativas consideradas

| Alternativa | Motivo da rejeição |
|---|---|
| Publicar direto após o commit (`@TransactionalEventListener` / *after commit*) | A mensagem se perde se o pod cair entre o commit e a publicação, e não há retry durável |
| CDC com Debezium lendo o WAL | Kafka Connect e mais infraestrutura no Academy para resolver o que uma tabela e um `@Scheduled` resolvem |
| SQS FIFO com deduplicação | A janela de 5 min não cobre reentregas mais tardias, e não resolve o *dual write* |
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
