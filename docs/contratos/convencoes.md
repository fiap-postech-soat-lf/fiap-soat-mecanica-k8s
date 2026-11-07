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
| [`OrdemServicoCancelada`](https://github.com/fiap-postech-soat-lf/fiap-soat-mecanica-os/blob/main/docs/contratos/OrdemServicoCancelada.v1.schema.json) | evento | os → identity e execucao | `SNS mecanica-os-eventos` (o Execução recebe pela fila `mecanica-execucao-os-eventos`, assinatura filtrada por `type`) |
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

Os eventos de `mecanica-os-eventos` também vão para os logs do Datadog. O Identity consome `SituacaoOrdemServicoAlterada` e `OrdemServicoCancelada` para notificar o cliente. O Execução consome só `OrdemServicoCancelada` (a ordem sai da fila do mecânico, F5-b).

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
| SQS (+ `-dlq`) | `mecanica-execucao-os-eventos` | execucao (F5-b) |
| Assinatura (raw) | `execucao-eventos` → `os-saga-respostas` | os |
| Assinatura (raw) | `billing-eventos` → `os-saga-respostas` | os |
| Assinatura (raw) | `os-eventos` → `identity-notificacoes` | **os** (exceção à regra "o consumidor é dono", F4-a; ADR-F4-03). O Identity só cria a fila e a queue policy |
| Assinatura (raw, filtrada) | `os-eventos` → `execucao-os-eventos`, com `filter_policy = {type = ["OrdemServicoCancelada"]}` | **os** (segunda exceção, F5-b; ADR-F4-03). O Execução só cria a fila e a queue policy, com o ARN do tópico montado pelo nome |
| ECR | `mecanica-<svc>` | cada serviço |
| RDS | `mecanica-<svc>-db` (identity, os, billing) | cada serviço via módulo `-db@v1` |
| Secrets Manager | `mecanica-<svc>-db`, `mecanica-identity-jwt` | cada serviço |
| Secrets Manager | `mercadopago-access-token`, `mercadopago-webhook-secret` (`recovery_window_in_days = 0`; chegam ao pod como `MP_ACCESS_TOKEN` e `MP_WEBHOOK_SECRET` pelo `app_secrets`, F6-m) | billing (só o Billing consome) |
| Webhook (fora do Terraform) | `callback` e `callback_sandbox` (tópico `payment`) da aplicação `mecanica-fase4` no Mercado Pago, apontando para `<api-url>/webhooks/mercadopago` | billing: regravado a cada janela com pagamento pelo MCP `save_webhook` ou pelo painel, porque o API Gateway é recriado a cada subida (F6-j) |
| DynamoDB (on-demand) | `execucao-ordens` (GSI esparso `fila`), `execucao-pecas`, `execucao-reservas`, `execucao-outbox` (GSI esparso `pendentes`, TTL), `execucao-idempotencia` (TTL), `execucao-tempos` | execucao (modelagem na RFC-F4-02) |
| SSM | `/mecanica/<repo-curto>/<chave>` (ex.: `/mecanica/k8s/cluster-name`, `/mecanica/k8s/nlb-dns`, `/mecanica/os/os-eventos-topic-arn`, `/mecanica/auth/api-url`); lista dos parâmetros na seção 2.7 | quem cria o recurso |

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
- **Contrato infra → CD** (o Identity a partir da F2, os demais quando ganharem `infra/`): `infra/outputs.tf` expõe `ecr_repository_url` (string), `app_config` (map(string), vira o ConfigMap) e `app_secrets` (map(string), `sensitive = true`, vira o Secret). Valores multilinha (PEM) vão com `\n` escapado, porque o `--from-env-file` não aceita quebra de linha.

### 2.7 Parâmetros SSM (ADR-F4-14)
Todos `String` (ou `StringList`), lidos com `insecure_value` nos data sources para não virarem valores sensíveis no plano. Só a chave pública é publicada; nenhum segredo vai para o SSM.

Os parâmetros de outro serviço (Identity, Execução e Billing, lidos pelo OS; na F5, o OS lê três do Execução) são lidos com `data "aws_ssm_parameter"` **direto**, não condicional. Na ordem B4 o dono sempre aplica antes, e a falta de um parâmetro é um erro (`ParameterNotFound` no `plan`), melhor do que subir uma Saga sem destino.

| Parâmetro | Tipo | Dono | Consumidor |
|---|---|---|---|
| `/mecanica/k8s/cluster-name` | String | `-k8s` | porteiro do `servico-cd` e do `cd.yml` do `-auth`; scripts. **Sinal de "ambiente ligado"**: criado por último no apply (`depends_on` nos helm releases e no NLB) |
| `/mecanica/k8s/nlb-dns` | String | `-k8s` | `infra/` do `-auth` (destino das integrações) |
| `/mecanica/k8s/vpc-id` | String | `-k8s` | `infra/` dos serviços (módulo `-db`) |
| `/mecanica/k8s/subnet-ids` | StringList | `-k8s` | idem |
| `/mecanica/k8s/node-security-group-id` | String | `-k8s` | idem (`allowed_security_group_ids`): é o SG do cluster que o EKS aplica aos nodes |
| `/mecanica/os/os-eventos-topic-arn` | String | os | Não é mais lido pelo Identity (F4-a). Continua publicado para os scripts e a F8 |
| `/mecanica/identity/notificacoes-queue-arn` | String | identity | `infra/` do OS (assinatura `os-eventos → identity-notificacoes`, F4-a) |
| `/mecanica/execucao/execucao-eventos-topic-arn` | String | execucao | `infra/` do OS (assinatura e policy da `os-saga-respostas`) |
| `/mecanica/execucao/execucao-comandos-queue-url` | String | execucao | `infra/` do OS (`MESSAGING_DESTINO_EXECUCAO_COMANDOS`) |
| `/mecanica/execucao/os-eventos-queue-arn` | String | execucao | `infra/` do OS (assinatura filtrada `os-eventos → execucao-os-eventos`, F5-b) |
| `/mecanica/billing/billing-eventos-topic-arn` | String | billing | `infra/` do OS |
| `/mecanica/billing/billing-comandos-queue-url` | String | billing | `infra/` do OS (`MESSAGING_DESTINO_BILLING_COMANDOS`) |
| `/mecanica/identity/jwt-secret-arn` | String | identity | `scripts/smoke-borda.sh` (assina o token de teste) |
| `/mecanica/identity/jwt-public-key` | String | identity | `infra/` do `-auth` (env `JWT_PUBLIC_KEY` da Lambda) e dos serviços `execucao`, `billing` e `os` (`JWT_PUBLIC_KEY` do `app_config`) |
| `/mecanica/auth/api-url` | String | `-auth` | smoke do `servico-cd`; scripts |

### 2.7.1 Ordem de provisionamento (B4)
```
cluster.yml (-k8s)
  └─ identity     RDS, ECR, par JWT, fila de notificações → SSM jwt-public-key, notificacoes-queue-arn
      └─ execucao ECR, 6 tabelas DynamoDB, tópico de eventos, filas de comandos e os-eventos → SSM (lê jwt-public-key)
          └─ billing  ECR, RDS, tópico de eventos, fila de comandos → SSM (lê jwt-public-key)
              └─ os   RDS, ECR, tópico os-eventos, fila os-saga-respostas, 4 assinaturas (lê tudo acima)
                  └─ -auth   API GW + authorizer (lê nlb-dns e jwt-public-key)
                      └─ smoke-borda.sh
```
Destruição, inversa: `-auth` → `os` → `billing` → `execucao` → `identity` → cluster. O OS sai antes dos tópicos e da fila que ele assina. O `subir-ambiente.sh` usa `SERVICOS=(identity execucao billing os)`. Motivo: o OS, o Billing e o Execução precisam da chave pública do JWT, que só existe depois do `apply` do Identity (ADR-F4-03).

### 2.8 Recursos do cluster e da borda
| Recurso | Nome | Repo |
|---|---|---|
| Launch template dos nodes | `mecanica-nodes-*` (`name_prefix`) | `-k8s` |
| NLB / target group / SG do NLB | `mecanica-nlb` / `mecanica-traefik` / `mecanica-nlb` | `-k8s` |
| Echo de diagnóstico | Deployment, Service e IngressRoute `mecanica-echo` (`traefik/whoami`), rota `/health-echo` | `-k8s` (`k8s/echo.yaml`) |
| Lambda | `mecanica-authorizer` (log group `/aws/lambda/mecanica-authorizer`, retenção de 7 dias) | `-auth` |
| HTTP API | `mecanica-api`, stage `$default` (access log `/aws/apigateway/mecanica-api`, retenção de 7 dias) | `-auth` |
| Authorizer | `mecanica-jwt` | `-auth` |
| RDS / secret / SG do RDS | `mecanica-<svc>-db` / `mecanica-<svc>-db` / `mecanica-<svc>-db` | serviço, via módulo |

### 2.9 Destrutibilidade (todo `infra/`)
Cada janela de integração destrói e recria tudo. Por isso:
- Secrets Manager com `recovery_window_in_days = 0`. Sem isso, o nome fica reservado por 7 dias e o apply da janela seguinte falha.
- ECR com `force_delete = true`, porque um repositório com imagens não é apagado.
- ECR com `image_tag_mutability = "MUTABLE"`. O `workflow_dispatch` do CD reconstrói o mesmo SHA, e com tags imutáveis o push falharia.
- RDS com `skip_final_snapshot = true`, `deletion_protection = false` e `backup_retention_period = 0` (cria mais rápido, sem backup automático).
- Log groups criados pelo Terraform, com retenção curta. Nada de log group criado implicitamente pela AWS.

### 2.10 Git e PR
- Branches curtas: `feat/<assunto>`, `fix/<assunto>`, `chore/<assunto>`, `docs/<assunto>`.
- Commits no padrão Conventional Commits, em português (`feat: adiciona outbox SQL ao esqueleto`).
- PR → `gh pr merge --auto --squash --delete-branch`. Só squash merge.
