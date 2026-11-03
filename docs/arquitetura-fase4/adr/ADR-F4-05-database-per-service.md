# ADR-F4-05: Database per service — 3 RDS Postgres e DynamoDB no Execução

- **Status:** Aceito
- **Data:** 2026-11-02 (decidido no planejamento da Fase 4 e registrado na F1)
- **Escopo:** transversal
- **Implementação:** módulo `rds-postgres` do `fiap-soat-mecanica-db` (`@v1`), usado pelo `infra/` de Identity, OS e Billing a partir da F3; DynamoDB do Execução na F5 (RFC-F4-02); `V1__mensageria.sql` no esqueleto

## Contexto

O monolito usava um único RDS, com FKs entre tudo: OS → veículo, OS → usuário, prestação → OS, alocação → peça. A Fase 4 exige banco próprio por serviço e ao menos um banco SQL e um NoSQL. O custo do Academy é limitado: cerca de US$ 6–7 por dia com o ambiente ligado (EKS, 3 nós, 3 RDS t3.micro e NLB), ou US$ 45–50 nas 7 janelas planejadas.

## Decisão

| Serviço | Banco | Dados |
|---|---|---|
| Identity | RDS Postgres `mecanica-identity-db` | `usuarios`, `clientes`, `veiculos` |
| OS | RDS Postgres `mecanica-os-db` | `ordens_servico`, `historico_situacao_os`, `servicos`, `saga_instancia`, `saga_passo` |
| Billing | RDS Postgres `mecanica-billing-db` | `orcamentos`, `itens_orcamento`, `pagamentos`, `webhook_eventos` |
| Execução | DynamoDB | `execucao-ordens` (prestações e peças aninhadas; GSI da fila), `execucao-pecas`, `execucao-reservas` |

Cada serviço SQL também tem `outbox` e `mensagem_processada` (ADR-F4-04). O Execução tem `execucao-outbox` e `execucao-idempotencia`.

- **Instâncias:** os 3 RDS saem do mesmo módulo `-db@v1` (`db.t3.micro`), com a credencial no Secrets Manager (`mecanica-<svc>-db`).
- **Migrations:** cada serviço é dono do seu Flyway. `V1` é sempre a mensageria, e as migrations de domínio começam em `V2`.
- **FKs entre contextos:** viram UUID simples.
  - **Veículo da OS:** o OS valida por REST no Identity e guarda o snapshot de `placa` e `cliente_id`.
  - **Usuário:** vem do `sub` do JWT.
  - **Serviço do catálogo:** o Execução valida por REST no OS (com cache) e guarda o nome.
- **DynamoDB no Execução:** é o NoSQL do requisito. Atende o documento aninhado da OS de oficina e a reserva de estoque com `TransactWriteItems` condicional.

## Alternativas consideradas

| Alternativa | Motivo da rejeição |
|---|---|
| Um RDS com 3 databases (ou 3 schemas) | Custaria cerca de 1/3 do RDS, mas a instância viraria ponto único de falha e de recurso entre os serviços, e o requisito pede infraestrutura própria por serviço. É uma decisão fixa do plano, fora da lista de cortes |
| DynamoDB em todos | Identity e Billing têm consultas relacionais e unicidade (CPF, e-mail, orçamento por OS), que ficam mais simples em SQL, e as migrations do monolito deixariam de ser reaproveitadas |
| Postgres também no Execução (JSONB) | Não cumpre o requisito de NoSQL, e a reserva atômica de várias peças fica em `SELECT ... FOR UPDATE` em vez de escrita condicional |

## Consequências

**Positivas**
- **Isolamento:** nenhum serviço lê a tabela de outro. Uma mudança de schema afeta só o dono, e a integração passa por contrato (REST ou mensagem).
- **Escala por perfil:** o Execução escala a escrita sem disputar recursos do RDS de cadastro.
- **Testes:** os testes de cada serviço sobem só o seu banco (Testcontainers Postgres ou LocalStack).

**Negativas / riscos**
- **Custo:** 3 RDS são a maior parte do custo diário.
- **Dados entre serviços:** relatórios que cruzam serviços exigem composição na API ou dados replicados por evento.
- **Snapshots desatualizados:** o snapshot de `placa` na OS pode divergir se o veículo mudar depois, o que é aceito, porque a OS registra o veículo do atendimento.
