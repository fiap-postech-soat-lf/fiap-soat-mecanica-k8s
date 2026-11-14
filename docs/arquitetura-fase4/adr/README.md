# ADRs da Fase 4

Decisões de arquitetura transversais da Fase 4 (os 7 repositórios). As decisões específicas de um serviço ficam no `docs/adr/` do próprio serviço. Formato: **Contexto · Decisão · Alternativas consideradas · Consequências**, como as ADRs do monolito (`fiap-soat-mecanica-api/docs/adr/`).

| ADR | Decisão | Status |
|---|---|---|
| [ADR-F4-01](ADR-F4-01-decomposicao-em-4-servicos.md) | Decomposição em 4 serviços por bounded context (Identity, OS, Billing, Execução) | Aceito |
| [ADR-F4-02](ADR-F4-02-saga-orquestrada.md) | Saga orquestrada no OS, com pivô em `IniciarExecucao` e só recuperação para frente depois dele; OS `CANCELADA` na hora da decisão, timeouts e reenvio (revisada na F4 e na F6: TTL do orçamento no Billing e cobrança só para a frente) | Aceito |
| [ADR-F4-03](ADR-F4-03-sns-sqs-sdk-v2.md) | SNS + SQS (comando → fila do consumidor, evento → tópico do produtor, raw delivery, DLQ) com AWS SDK v2 direto; assinaturas do `os-eventos` no `infra/` do OS (Identity e, filtrada por `type`, Execução) e ordem B4 `identity → execucao → billing → os → auth` (revisada na F4 e na F5) | Aceito |
| [ADR-F4-04](ADR-F4-04-outbox-consumidor-idempotente.md) | Transactional Outbox (`FOR UPDATE SKIP LOCKED`) e consumidor idempotente por `messageId`; reenvio com `messageId` novo e `SKIP LOCKED` nos timeouts; variante DynamoDB do Execução; idempotência por chave de negócio em SQL (`comando_atendido`) e do webhook por `(payment.id, status)` no Billing (revisada na F4, na F5 e na F6) | Aceito |
| [ADR-F4-05](ADR-F4-05-database-per-service.md) | Database per service: 3 RDS Postgres e 6 tabelas DynamoDB no Execução (revisada na F5) | Aceito |
| [ADR-F4-06](ADR-F4-06-borda-api-gateway-authorizer-nlb.md) | Borda: HTTP API + Lambda Authorizer + NLB público → Traefik NodePort; duas integrações; rotas públicas explícitas; 401 sem token e 403 com token inválido | Aceito |
| [ADR-F4-07](ADR-F4-07-jwt-rs256.md) | JWT RS256 emitido pelo Identity: par gerado no Terraform, chave pública no SSM, chave nova a cada janela | Aceito |
| [ADR-F4-08](ADR-F4-08-ecr-por-servico.md) | Um repositório ECR por serviço no `infra/` do serviço, `MUTABLE` e `force_delete` | Aceito |
| [ADR-F4-09](ADR-F4-09-rest-sincrono-resilience4j.md) | REST síncrono (veículo e catálogo): timeout de 2 s, retry sem circuit breaker, repasse do JWT só nos clientes do Identity e do OS (revisada na F5) | Aceito |
| [ADR-F4-10](ADR-F4-10-observabilidade.md) | Observabilidade: collector + agente Java → Datadog; trace restaurado no outbox pelo `traceparent` do envelope; `osId`/`sagaId` como chave da OS; logs OTLP com MDC; dashboards e monitores como código, sem notificação | Aceito |
| [ADR-F4-11](ADR-F4-11-pipeline-padrao-e-ruleset.md) | Reusable workflows `@v1` e ruleset da `main` com PR e checks obrigatórios e 0 aprovações | Aceito |
| [ADR-F4-12](ADR-F4-12-notificacoes-no-identity.md) | Notificações no Identity: consome `os-eventos`, adapter de log; a assinatura é do `infra/` do OS (revisada na F4) | Aceito |
| [ADR-F4-13](ADR-F4-13-recomeco-limpo-seeds-uuids-estaveis.md) | Recomeço limpo: Flyway e seed por serviço com os UUIDs do V9, runner condicional do DynamoDB e sem migração de dados do monolito | Aceito |
| [ADR-F4-14](ADR-F4-14-ssm-entre-repositorios.md) | Configuração entre repositórios via SSM Parameter Store e bucket de state derivado do account ID | Aceito |

RFCs em [`../rfc/`](../rfc/):

| RFC | Tema | Status |
|---|---|---|
| [RFC-F4-01](../rfc/RFC-F4-01-mercado-pago.md) | Mercado Pago: Checkout Pro com cartões APRO e OTHE, webhook na aplicação dona do token, validação do `x-signature`, status consultado e idempotência por `(payment.id, status)` | Aprovado (F6) |
| [RFC-F4-02](../rfc/RFC-F4-02-modelagem-dynamodb-execucao.md) | Modelagem DynamoDB do Execução: 6 tabelas, GSIs esparsos `fila` e `pendentes`, estoque materializado e reserva atômica | Aprovado (F5) |
| [RFC-F4-03](../rfc/RFC-F4-03-capacidade-e-custo.md) | Capacidade e custo do ambiente no Academy (medidos até a F8; F9 estimada) | Aprovado |
