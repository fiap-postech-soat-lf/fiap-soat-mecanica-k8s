# Convenções e contratos da Fase 4

> **Regra de congelamento.** Os contratos foram congelados no fim da F1. Depois disso, mudar um contrato exige um PR no repositório do **produtor** alterando o schema, o exemplo e o teste (`ContratoSchemaTest`).
> - **Campo novo opcional:** mantém a `version`.
> - **Remover ou renomear um campo, ou torná-lo obrigatório:** cria `<Tipo>.v2`, e o consumidor passa a aceitar as duas versões até a v1 sair de uso.
> - O envelope tem `additionalProperties: false`; os payloads, `true` (um consumidor ignora campos que não conhece).

Documentos deste diretório:

| Arquivo | Conteúdo |
|---|---|
| [`envelope.schema.json`](envelope.schema.json) | Envelope comum de todas as mensagens (fonte; cada serviço tem uma cópia idêntica, vinda do template) |
| [`rotas.md`](rotas.md) | Prefixos de rota por serviço (IngressRoutes do Traefik e rotas do API Gateway no `-auth`) |
| [`jwt.md`](jwt.md) | Formato do JWT emitido pelo Identity e regras de validação |

## 1. Mensagens

- Cada mensagem é um envelope (`messageId`, `type`, `version`, `sagaId?`, `osId?`, `correlationId`, `causationId?`, `occurredAt`, `traceparent?`, `payload`).
- O schema do payload fica no repositório do produtor: `docs/contratos/<Tipo>.v<N>.schema.json`, com um envelope de exemplo em `docs/contratos/exemplos/<Tipo>.v<N>.json`.
- Comandos vão para a **fila do consumidor**; eventos, para o **tópico do produtor**, assinado com entrega raw.
- Tipos de dados:
  - ids são UUID;
  - datas são `date-time` (RFC 3339, UTC);
  - valores monetários são `number` com até 2 casas (`multipleOf: 0.01`), lidos como `BigDecimal`;
  - placas seguem `^[A-Z]{3}[0-9][A-Z0-9][0-9]{2}$` (antiga ou Mercosul, sem hífen).
- Nomes de campo por extenso (`quantidade`, `valorUnitario`, `precoMaoDeObra`).

| Tipo | Natureza | Produtor → consumidor | Canal |
|---|---|---|---|
| [`AbrirDiagnostico`](https://github.com/fiap-postech-soat-lf/fiap-soat-mecanica-os/blob/main/docs/contratos/AbrirDiagnostico.v1.schema.json) | comando | os → execucao | `SQS mecanica-execucao-comandos` |
| [`ReservarPecas`](https://github.com/fiap-postech-soat-lf/fiap-soat-mecanica-os/blob/main/docs/contratos/ReservarPecas.v1.schema.json) | comando | os → execucao | `SQS mecanica-execucao-comandos` |
| [`LiberarReservaPecas`](https://github.com/fiap-postech-soat-lf/fiap-soat-mecanica-os/blob/main/docs/contratos/LiberarReservaPecas.v1.schema.json) | comando | os → execucao | `SQS mecanica-execucao-comandos` |
| [`GerarOrcamento`](https://github.com/fiap-postech-soat-lf/fiap-soat-mecanica-os/blob/main/docs/contratos/GerarOrcamento.v1.schema.json) | comando | os → billing | `SQS mecanica-billing-comandos` |
| [`CancelarOrcamento`](https://github.com/fiap-postech-soat-lf/fiap-soat-mecanica-os/blob/main/docs/contratos/CancelarOrcamento.v1.schema.json) | comando | os → billing | `SQS mecanica-billing-comandos` |
| [`IniciarExecucao`](https://github.com/fiap-postech-soat-lf/fiap-soat-mecanica-os/blob/main/docs/contratos/IniciarExecucao.v1.schema.json) | comando | os → execucao | `SQS mecanica-execucao-comandos` |
| [`SolicitarPagamento`](https://github.com/fiap-postech-soat-lf/fiap-soat-mecanica-os/blob/main/docs/contratos/SolicitarPagamento.v1.schema.json) | comando | os → billing | `SQS mecanica-billing-comandos` |
| [`SituacaoOrdemServicoAlterada`](https://github.com/fiap-postech-soat-lf/fiap-soat-mecanica-os/blob/main/docs/contratos/SituacaoOrdemServicoAlterada.v1.schema.json) | evento | os → identity | `SNS mecanica-os-eventos` |
| [`OrdemServicoCancelada`](https://github.com/fiap-postech-soat-lf/fiap-soat-mecanica-os/blob/main/docs/contratos/OrdemServicoCancelada.v1.schema.json) | evento | os → identity | `SNS mecanica-os-eventos` |
| [`DiagnosticoAberto`](https://github.com/fiap-postech-soat-lf/fiap-soat-mecanica-execucao/blob/main/docs/contratos/DiagnosticoAberto.v1.schema.json) | evento | execucao → os | `SNS mecanica-execucao-eventos` |
| [`DiagnosticoConcluido`](https://github.com/fiap-postech-soat-lf/fiap-soat-mecanica-execucao/blob/main/docs/contratos/DiagnosticoConcluido.v1.schema.json) | evento | execucao → os | `SNS mecanica-execucao-eventos` |
| [`PecasReservadas`](https://github.com/fiap-postech-soat-lf/fiap-soat-mecanica-execucao/blob/main/docs/contratos/PecasReservadas.v1.schema.json) | evento | execucao → os | `SNS mecanica-execucao-eventos` |
| [`ReservaPecasRecusada`](https://github.com/fiap-postech-soat-lf/fiap-soat-mecanica-execucao/blob/main/docs/contratos/ReservaPecasRecusada.v1.schema.json) | evento | execucao → os | `SNS mecanica-execucao-eventos` |
| [`ReservaPecasLiberada`](https://github.com/fiap-postech-soat-lf/fiap-soat-mecanica-execucao/blob/main/docs/contratos/ReservaPecasLiberada.v1.schema.json) | evento | execucao → os | `SNS mecanica-execucao-eventos` |
| [`ExecucaoIniciada`](https://github.com/fiap-postech-soat-lf/fiap-soat-mecanica-execucao/blob/main/docs/contratos/ExecucaoIniciada.v1.schema.json) | evento | execucao → os | `SNS mecanica-execucao-eventos` |
| [`ExecucaoFinalizada`](https://github.com/fiap-postech-soat-lf/fiap-soat-mecanica-execucao/blob/main/docs/contratos/ExecucaoFinalizada.v1.schema.json) | evento | execucao → os | `SNS mecanica-execucao-eventos` |
| [`OrcamentoGerado`](https://github.com/fiap-postech-soat-lf/fiap-soat-mecanica-billing/blob/main/docs/contratos/OrcamentoGerado.v1.schema.json) | evento | billing → os | `SNS mecanica-billing-eventos` |
| [`OrcamentoFalhou`](https://github.com/fiap-postech-soat-lf/fiap-soat-mecanica-billing/blob/main/docs/contratos/OrcamentoFalhou.v1.schema.json) | evento | billing → os | `SNS mecanica-billing-eventos` |
| [`OrcamentoAprovado`](https://github.com/fiap-postech-soat-lf/fiap-soat-mecanica-billing/blob/main/docs/contratos/OrcamentoAprovado.v1.schema.json) | evento | billing → os | `SNS mecanica-billing-eventos` |
| [`OrcamentoRecusado`](https://github.com/fiap-postech-soat-lf/fiap-soat-mecanica-billing/blob/main/docs/contratos/OrcamentoRecusado.v1.schema.json) | evento | billing → os | `SNS mecanica-billing-eventos` |
| [`OrcamentoExpirado`](https://github.com/fiap-postech-soat-lf/fiap-soat-mecanica-billing/blob/main/docs/contratos/OrcamentoExpirado.v1.schema.json) | evento | billing → os | `SNS mecanica-billing-eventos` |
| [`CobrancaCriada`](https://github.com/fiap-postech-soat-lf/fiap-soat-mecanica-billing/blob/main/docs/contratos/CobrancaCriada.v1.schema.json) | evento | billing → os | `SNS mecanica-billing-eventos` |
| [`PagamentoConfirmado`](https://github.com/fiap-postech-soat-lf/fiap-soat-mecanica-billing/blob/main/docs/contratos/PagamentoConfirmado.v1.schema.json) | evento | billing → os | `SNS mecanica-billing-eventos` |
| [`PagamentoRecusado`](https://github.com/fiap-postech-soat-lf/fiap-soat-mecanica-billing/blob/main/docs/contratos/PagamentoRecusado.v1.schema.json) | evento | billing → os | `SNS mecanica-billing-eventos` |

Os eventos de `mecanica-os-eventos` também vão para os logs do Datadog. O Identity consome `SituacaoOrdemServicoAlterada` e `OrdemServicoCancelada` para notificar o cliente.

## 2. Convenções gerais

### 2.1 Repositórios
| Repo | Tipo | Check obrigatório | Sonar |
|---|---|---|---|
| `fiap-soat-mecanica-identity` | Serviço Spring (SQL) | `ci / build` + `SonarCloud Code Analysis` | sim |
| `fiap-soat-mecanica-os` | Serviço Spring (SQL) | idem | sim |
| `fiap-soat-mecanica-billing` | Serviço Spring (SQL) | idem | sim |
| `fiap-soat-mecanica-execucao` | Serviço Spring (DynamoDB) | idem | sim |
| `fiap-soat-mecanica-auth` | Lambda Java 21 + Terraform | idem | sim |
| `fiap-soat-mecanica-db` | Módulo Terraform | `ci / terraform` | não |
| `fiap-soat-mecanica-k8s` | Terraform + workflows + templates | `ci / terraform` | não |

### 2.2 Código Java
| Item | Convenção |
|---|---|
| `groupId` | `br.com.fiap.soat` |
| `artifactId` | `fiap-soat-mecanica-<svc>` |
| Pacote base | `br.com.fiap.soat.mecanica.<svc>` (`identity`, `os`, `billing`, `execucao`; o `-auth` usa `...mecanica.auth`) |
| Camadas | Mesmas do monolito: `domain/`, `application/`, `adapters/in|out/`, `config/`. `domain` e `application` não dependem de `adapters` nem de Spring Web |
| Classe principal | `<Svc>Application` (`IdentityApplication`, `OsApplication`, `BillingApplication`, `ExecucaoApplication`) |
| Spring Boot | 3.5.14 (igual ao monolito) |
| Java | 21 (virtual threads habilitadas: `spring.threads.virtual.enabled=true`) |

### 2.3 Portas locais
| Serviço | `server.port` (perfil `local`) | Postgres local | Banco |
|---|---|---|---|
| identity | 8081 | 5433 | `identity` |
| os | 8082 | 5434 | `os` |
| billing | 8083 | 5435 | `billing` |
| execucao | 8084 | — (LocalStack DynamoDB) | — |
| LocalStack | 4566 | — | — |

No container (EKS) todos usam a porta **8080**.

### 2.4 Nomes de recursos AWS (iguais no Terraform e no LocalStack)
| Tipo | Nome | Dono (Terraform) |
|---|---|---|
| SNS | `mecanica-execucao-eventos` | execucao |
| SNS | `mecanica-billing-eventos` | billing |
| SNS | `mecanica-os-eventos` | os |
| SQS (+ `-dlq`) | `mecanica-execucao-comandos` | execucao |
| SQS (+ `-dlq`) | `mecanica-billing-comandos` | billing |
| SQS (+ `-dlq`) | `mecanica-os-saga-respostas` | os |
| SQS (+ `-dlq`) | `mecanica-identity-notificacoes` | identity |
| Assinatura (raw) | `execucao-eventos` → `os-saga-respostas` | os |
| Assinatura (raw) | `billing-eventos` → `os-saga-respostas` | os |
| Assinatura (raw) | `os-eventos` → `identity-notificacoes` | identity |
| ECR | `mecanica-<svc>` | cada serviço |
| RDS | `mecanica-<svc>-db` (identity, os, billing) | cada serviço via módulo `-db@v1` |
| Secrets Manager | `mecanica-<svc>-db`, `mecanica-identity-jwt`, `mercadopago-access-token`, `mercadopago-webhook-secret` | cada serviço |
| DynamoDB | `execucao-ordens`, `execucao-pecas`, `execucao-reservas`, `execucao-outbox`, `execucao-idempotencia` | execucao (modelagem na RFC-F4-02, F5) |
| SSM | `/mecanica/<repo-curto>/<chave>` (ex.: `/mecanica/k8s/cluster-name`, `/mecanica/k8s/nlb-dns`, `/mecanica/os/os-eventos-topic-arn`, `/mecanica/auth/api-url`) | quem cria o recurso |

Todas as filas são padrão (não FIFO), com `visibility_timeout_seconds = 30`, `message_retention_seconds = 345600` (4 dias) e redrive para a DLQ com `maxReceiveCount = 5`.

### 2.5 Kubernetes e Datadog
| Item | Convenção |
|---|---|
| Namespace | `mecanica` |
| Deployment / Service | `mecanica-<svc>` (Service `ClusterIP`, porta 8080) |
| Secret / ConfigMap | `mecanica-<svc>-secret` / `mecanica-<svc>-config` |
| Rotas externas | IngressRoute do Traefik por prefixo de recurso ([rotas.md](rotas.md)) |
| Health e Swagger externos | `/<svc>/actuator/health` e `/<svc>/swagger-ui.html` via middleware `StripPrefix` (o Traefik envia `X-Forwarded-Prefix`, e o Spring usa `server.forward-headers-strategy=framework`) |
| Tags Datadog | `service=mecanica-<svc>`, `env=prd`, `version=<sha curto>` |

### 2.6 Terraform
- Backend S3 `mecanica-tfstate-<accountId>` em `us-east-1`, `use_lockfile = true`, key **`<nome-do-repo>/terraform.tfstate`** (ex.: `fiap-soat-mecanica-identity/terraform.tfstate`).
- O bucket **não** é guardado em variável: os workflows calculam `mecanica-tfstate-$(aws sts get-caller-identity --query Account --output text)`. Isso evita reconfigurar quando o Academy mudar de conta.
- `backend.tf` só com `backend "s3" {}`; o resto vai por `-backend-config` no workflow.
- Provider AWS `~> 6.0`; `required_version = ">= 1.10.0, < 2.0.0"`.
- **Contrato infra → CD** (todo serviço segue a partir da F3): `infra/outputs.tf` expõe `ecr_repository_url` (string), `app_config` (map(string), vira o ConfigMap) e `app_secrets` (map(string), `sensitive = true`, vira o Secret).

### 2.7 Git e PR
- Branches curtas: `feat/<assunto>`, `fix/<assunto>`, `chore/<assunto>`, `docs/<assunto>`.
- Commits no padrão Conventional Commits, em português (`feat: adiciona outbox SQL ao esqueleto`).
- PR → `gh pr merge --auto --squash --delete-branch`. Só squash merge.
