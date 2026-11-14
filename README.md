# fiap-soat-mecanica-k8s

Infraestrutura compartilhada da **Fase 4** da Oficina Mecânica do Braia (Tech Challenge FIAP SOAT): cluster EKS e add-ons, workflows reutilizáveis de CI/CD, template dos microsserviços, ambiente local e documentação de arquitetura.

Visão geral da arquitetura: [diagrama da AWS](docs/arquitetura-fase4/diagrama/arquitetura-aws-fase4.png) (4 serviços, 3 RDS Postgres e DynamoDB, SNS + SQS, API Gateway com Lambda Authorizer, Traefik no EKS e Datadog). Decisões em [`docs/arquitetura-fase4/adr/`](docs/arquitetura-fase4/adr/README.md) e RFCs em [`docs/arquitetura-fase4/rfc/`](docs/arquitetura-fase4/rfc/). Vídeo da entrega: *link entra depois do upload*.

## Repositórios da Fase 4

Todos na org [`fiap-postech-soat-lf`](https://github.com/fiap-postech-soat-lf):

| Repositório | Papel |
|---|---|
| [`fiap-soat-mecanica-identity`](https://github.com/fiap-postech-soat-lf/fiap-soat-mecanica-identity) | Clientes, veículos, funcionários, login (staff e CPF) e notificações |
| [`fiap-soat-mecanica-os`](https://github.com/fiap-postech-soat-lf/fiap-soat-mecanica-os) | Ordens de serviço, catálogo e orquestrador da Saga |
| [`fiap-soat-mecanica-billing`](https://github.com/fiap-postech-soat-lf/fiap-soat-mecanica-billing) | Orçamento e pagamento (Mercado Pago) |
| [`fiap-soat-mecanica-execucao`](https://github.com/fiap-postech-soat-lf/fiap-soat-mecanica-execucao) | Diagnóstico, fila de execução, peças e estoque (DynamoDB) |
| [`fiap-soat-mecanica-auth`](https://github.com/fiap-postech-soat-lf/fiap-soat-mecanica-auth) | Lambda Authorizer + API Gateway |
| [`fiap-soat-mecanica-db`](https://github.com/fiap-postech-soat-lf/fiap-soat-mecanica-db) | Módulo Terraform `rds-postgres` |
| **`fiap-soat-mecanica-k8s`** (este) | EKS, add-ons, reusable workflows, template dos serviços, ambiente local |

## Cobertura e Quality Gate (SonarCloud)

Leitura da API pública do SonarCloud em 2026-11-14, na `main` de cada repositório (projeto `fiap-postech-soat-lf_<repositório>`). O CI (`ci / build`) falha se o Quality Gate falhar, e o JaCoCo exige ≥ 80% de linhas.

| Repositório | Cobertura | Quality Gate |
|---|---|---|
| `-identity` | 95,5% | OK |
| `-os` | 95,4% | OK |
| `-billing` | 96,0% | OK |
| `-execucao` | 95,7% | OK |
| `-auth` | 98,8% | OK |

O `-db` e este repositório são só Terraform e scripts, com o check `ci / terraform`. Cada README de serviço tem os badges de cobertura e do gate.

## Estrutura

| Pasta | Conteúdo |
|---|---|
| `scripts/` | Scripts de administração da org e da conta AWS (criação de repos, secrets, ruleset, bootstrap do state, geração de serviço) |
| `.github/workflows/` | Reusable workflows `servico-ci.yml`, `servico-cd.yml` e `terraform-ci.yml` (tag `v1`) e o `ci.yml` deste repo |
| `templates/servico-base/` | Esqueleto comum dos 4 serviços (placeholder `servicobase`; partes só de SQL entre marcadores `[SQL]`/`[/SQL]`), validado pelo workflow `template.yml` |
| `local/` | `docker compose` com LocalStack (mensageria da tabela 3.4) e os Postgres dos serviços SQL, `verificar.sh` e JWT de dev (ver `local/README.md`) |
| `k8s/` | Manifestos compartilhados aplicados pelo `cluster.yml`: namespace `mecanica`, RBAC e OpenTelemetryCollector (DaemonSet → Datadog), Instrumentation `java-instrumentation` e o echo de diagnóstico `/health-echo` (`traefik/whoami`) |
| `terraform/` | EKS 1.37 + node group (3 × t3.medium, launch template IMDSv2 hop 2), add-on metrics-server, Traefik (NodePort 30090), OpenTelemetry Operator, NLB público na frente do Traefik e os parâmetros SSM `/mecanica/k8s/*`. Só roda pelo workflow `cluster.yml` (F2) |
| `docs/` | `contratos/` (convenções, envelope, JWT e rotas; ver `docs/contratos/convencoes.md`) e `arquitetura-fase4/adr/` (ADRs transversais F4-01 a F4-14 e RFCs) |

## Reusable workflows

| Workflow | Quem chama | Check gerado |
|---|---|---|
| `servico-ci.yml` | 4 serviços e `-auth` (`ci.yml`) | `ci / build` |
| `terraform-ci.yml` | `-db` (`@v1`) e este repo (caminho local) | `ci / terraform` |
| `servico-cd.yml` | 4 serviços (`cd.yml`, após o CI verde na `main`) | — |

Os chamadores usam o job `ci` (ou `cd`), `secrets: inherit` e a tag móvel `@v1`. Para publicar uma mudança compatível, valide-a no `-auth` e depois mova a tag: `git tag -f v1 && git push -f origin v1` (mais o `v1.x.y` imutável). Mudança incompatível vira `v2`.

## Ambiente na AWS

O EKS só existe durante as janelas de integração. Merge no `-k8s` não liga nada: o `terraform/` só roda pelo workflow `Cluster` (`cluster.yml`, `workflow_dispatch`).

| Comando | Efeito |
|---|---|
| `scripts/subir-ambiente.sh` | Sobe tudo na ordem da B4 (cluster → serviços → `-auth` → smoke). ~40–50 min |
| `scripts/destruir-ambiente.sh` | Dispara o workflow `Destruir ambiente` (borda → serviços → cluster → órfãos) e confere os órfãos. ~20–25 min |

Os dois workflows usam o grupo de concorrência `ambiente`, então um nunca roda junto com o outro.

O `servico-cd.yml` só faz deploy a partir de `workflow_dispatch` ou do CI de **push** no próprio repositório (um PR de fork com uma branch chamada `main` não dispara o deploy). Ele termina verde sem deploy quando o SSM `/mecanica/k8s/cluster-name` não existe (EKS desligado) e falha pedindo `scripts/atualizar-credenciais.sh` quando as credenciais do Academy expiraram.

## Rotina de cada sessão do AWS Academy

As credenciais do Learner Lab expiram a cada 4 h. No início de **toda** sessão:

1. copie o bloco de "AWS Details → AWS CLI" para `~/.aws/credentials` (perfil `default`);
2. rode `scripts/atualizar-credenciais.sh` para atualizar os secrets `AWS_*` da org (ele valida as credenciais e mostra o account ID antes de gravar).

Os secrets fixos (`DATADOG_API_KEY`, `SONAR_TOKEN`, `MP_ACCESS_TOKEN`, `MP_WEBHOOK_SECRET`) só são regravados quando mudam: `scripts/atualizar-credenciais.sh --fixos` pede cada valor sem eco (Enter vazio pula). Os dois modos aceitam `--dry-run`.

## Pré-requisitos locais

Java 21, Docker + Compose v2, Terraform 1.15.8 (fixado em `.terraform-version` para o tfenv), AWS CLI v2, GitHub CLI 2.50+, `jq`, `envsubst`, `shellcheck`.
