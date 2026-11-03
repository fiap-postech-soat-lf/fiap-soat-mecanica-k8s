# ADRs da Fase 4

Decisões de arquitetura transversais da Fase 4 (os 7 repositórios). As decisões específicas de um serviço ficam no `docs/adr/` do próprio serviço. Formato: **Contexto · Decisão · Alternativas consideradas · Consequências**, como as ADRs do monolito (`fiap-soat-mecanica-api/docs/adr/`).

| ADR | Decisão | Status |
|---|---|---|
| [ADR-F4-01](ADR-F4-01-decomposicao-em-4-servicos.md) | Decomposição em 4 serviços por bounded context (Identity, OS, Billing, Execução) | Aceito |
| [ADR-F4-02](ADR-F4-02-saga-orquestrada.md) | Saga orquestrada no OS, com pivô em `IniciarExecucao` e só recuperação para frente depois dele | Aceito |
| [ADR-F4-03](ADR-F4-03-sns-sqs-sdk-v2.md) | SNS + SQS (comando → fila do consumidor, evento → tópico do produtor, raw delivery, DLQ) com AWS SDK v2 direto | Aceito |
| [ADR-F4-04](ADR-F4-04-outbox-consumidor-idempotente.md) | Transactional Outbox (`FOR UPDATE SKIP LOCKED`) e consumidor idempotente por `messageId` | Aceito |
| [ADR-F4-05](ADR-F4-05-database-per-service.md) | Database per service: 3 RDS Postgres e DynamoDB no Execução | Aceito |
| ADR-F4-06 a 10 | Borda (API Gateway + Authorizer + NLB → Traefik), JWT RS256, ECR, REST síncrono com Resilience4j, observabilidade | *TODO* (F2–F8) |
| [ADR-F4-11](ADR-F4-11-pipeline-padrao-e-ruleset.md) | Reusable workflows `@v1` e ruleset da `main` com PR e checks obrigatórios e 0 aprovações | Aceito |
| ADR-F4-12, 13 | Notificações no Identity; recomeço limpo com seeds de UUIDs estáveis | *TODO* (F3) |
| [ADR-F4-14](ADR-F4-14-ssm-entre-repositorios.md) | Configuração entre repositórios via SSM Parameter Store e bucket de state derivado do account ID | Aceito |

RFCs previstas em `docs/arquitetura-fase4/` (a partir da F2): RFC-F4-01 (Mercado Pago), RFC-F4-02 (modelagem DynamoDB do Execução) e RFC-F4-03 (capacidade e custo no Academy).
