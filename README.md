# fiap-soat-mecanica-k8s

Infraestrutura compartilhada da **Fase 4** da Oficina Mecânica do Braia (Tech Challenge FIAP SOAT): cluster EKS e add-ons, workflows reutilizáveis de CI/CD, template dos microsserviços, ambiente local e documentação de arquitetura.

> 🚧 Em construção (fase F1). As seções marcadas com *TODO* são preenchidas nas próximas fases.

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

## Estrutura

| Pasta | Conteúdo |
|---|---|
| `scripts/` | Scripts de administração da org e da conta AWS (criação de repos, secrets, ruleset, bootstrap do state, geração de serviço) |
| `.github/workflows/` | Reusable workflows `servico-ci.yml`, `servico-cd.yml` e `terraform-ci.yml` (tag `v1`) e o `ci.yml` deste repo |
| `templates/servico-base/` | Esqueleto comum dos 4 serviços (placeholder `servicobase`; partes só de SQL entre marcadores `[SQL]`/`[/SQL]`), validado pelo workflow `template.yml` |
| `local/` | *TODO (F1)* `docker compose` com LocalStack e Postgres para desenvolvimento |
| `terraform/` | Base (versions, backend S3, provider `aws`). *TODO (F2)* EKS, NLB, Traefik e OpenTelemetry |
| `docs/` | *TODO (F1)* Contratos, convenções e ADRs da Fase 4 |

## Reusable workflows

| Workflow | Quem chama | Check gerado |
|---|---|---|
| `servico-ci.yml` | 4 serviços e `-auth` (`ci.yml`) | `ci / build` |
| `terraform-ci.yml` | `-db` (`@v1`) e este repo (caminho local) | `ci / terraform` |
| `servico-cd.yml` | 4 serviços (`cd.yml`, após o CI verde na `main`) | — |

Os chamadores usam o job `ci` (ou `cd`), `secrets: inherit` e a tag móvel `@v1`. Para publicar uma mudança compatível, valide-a no `-auth` e depois mova a tag: `git tag -f v1 && git push -f origin v1` (mais o `v1.x.y` imutável). Mudança incompatível vira `v2`.

O `servico-cd.yml` termina verde sem deploy quando o SSM `/mecanica/k8s/cluster-name` não existe (EKS desligado) e falha pedindo `scripts/atualizar-credenciais.sh` quando as credenciais do Academy expiraram.

## Rotina de cada sessão do AWS Academy

As credenciais do Learner Lab expiram a cada 4 h. No início de **toda** sessão:

1. copie o bloco de "AWS Details → AWS CLI" para `~/.aws/credentials` (perfil `default`);
2. rode `scripts/atualizar-credenciais.sh` para atualizar os secrets `AWS_*` da org (ele valida as credenciais e mostra o account ID antes de gravar).

Os secrets fixos (`DATADOG_API_KEY`, `SONAR_TOKEN`, `MP_ACCESS_TOKEN`, `MP_WEBHOOK_SECRET`) só são regravados quando mudam: `scripts/atualizar-credenciais.sh --fixos` pede cada valor sem eco (Enter vazio pula). Os dois modos aceitam `--dry-run`.

## Pré-requisitos locais

Java 21, Docker + Compose v2, Terraform 1.15.8 (fixado em `.terraform-version` para o tfenv), AWS CLI v2, GitHub CLI 2.50+, `jq`, `envsubst`, `shellcheck`.

## Origem

Parte do conteúdo deste repositório é adaptada dos repositórios da Fase 3 do grupo (usados só para consulta). *TODO (F9)*: listar os repositórios de origem.
