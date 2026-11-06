# ADR-F4-05: Database per service — 3 RDS Postgres e DynamoDB no Execução

- **Status:** Aceito
- **Data:** 2026-11-02 (decidido no planejamento da Fase 4 e registrado na F1). Revisada em 2026-11-06 (F5: as 6 tabelas do Execução)
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
| Execução | DynamoDB (6 tabelas on-demand) | `execucao-ordens` (prestações e alocações aninhadas; GSI esparso `fila`), `execucao-pecas` (estoque materializado), `execucao-reservas`, `execucao-tempos` (tempo médio por serviço) |

Cada serviço SQL também tem `outbox` e `mensagem_processada` (ADR-F4-04). O Execução tem `execucao-outbox` (GSI esparso `pendentes`) e `execucao-idempotencia`, ambas com TTL.

- **Instâncias:** os 3 RDS saem do mesmo módulo `-db@v1` (`db.t3.micro`), com a credencial no Secrets Manager (`mecanica-<svc>-db`).
- **Migrations:** cada serviço é dono do seu Flyway. `V1` é sempre a mensageria, e as migrations de domínio começam em `V2`.
- **FKs entre contextos:** viram UUID simples.
  - **Veículo da OS:** o OS valida por REST no Identity e guarda o snapshot de `placa` e `cliente_id`.
  - **Usuário:** vem do `sub` do JWT.
  - **Serviço do catálogo:** o Execução valida por REST no OS (com cache) e guarda o nome.
- **DynamoDB no Execução:** é o NoSQL do requisito. A ordem de execução é um documento único, com prestações e alocações aninhadas, lido e escrito por `osId`. A reserva de estoque é uma **atualização condicional atômica** (`TransactWriteItems`): ou reserva todas as peças da OS, ou nenhuma, e a última unidade não é vendida duas vezes (provado pelo `ReservaConcorrenteIT`). A modelagem parte dos padrões de acesso e está na [RFC-F4-02](../rfc/RFC-F4-02-modelagem-dynamodb-execucao.md).
- **Tabela por finalidade, e não tabela única:** são 6 tabelas (as de negócio mais outbox e idempotência), e não *single-table design*, porque nenhum acesso lê tipos diferentes de uma vez.
- **Tempo médio:** a `TempoMedioServicoProjection` do monolito (que varria as ordens) virou a tabela `execucao-tempos`, atualizada com `ADD` na mesma transação que finaliza cada prestação (F5-d).
- **Seed:** as 3 peças do monolito (V9) entram por um `ApplicationRunner` com `Put` condicional, e não pelo Terraform, para que cada `apply` não devolva o estoque ao valor inicial.

## Alternativas consideradas

| Alternativa | Motivo da rejeição |
|---|---|
| Um RDS com 3 databases (ou 3 schemas) | Custaria cerca de 1/3 do RDS, mas a instância viraria ponto único de falha e de recurso entre os serviços, e o requisito pede infraestrutura própria por serviço. É uma decisão fixa do plano, fora da lista de cortes |
| DynamoDB em todos | Identity e Billing têm consultas relacionais e unicidade (CPF, e-mail, orçamento por OS), que ficam mais simples em SQL, e as migrations do monolito deixariam de ser reaproveitadas |
| Execução com tabelas do monolito (`prestacao_servico`, `alocacao_pecas`) no DynamoDB | Cada leitura viraria `Query` em três tabelas, e a unicidade entre itens exigiria transação a cada escrita. A ordem tem poucas dezenas de linhas e cabe num item |
| Postgres também no Execução (JSONB) | Não cumpre o requisito de NoSQL, e a reserva atômica de várias peças fica em `SELECT ... FOR UPDATE` em vez de escrita condicional |

## Consequências

**Positivas**
- **Isolamento:** nenhum serviço lê a tabela de outro. Uma mudança de schema afeta só o dono, e a integração passa por contrato (REST ou mensagem).
- **Escala por perfil:** o Execução escala a escrita sem disputar recursos do RDS de cadastro.
- **Testes:** os testes de cada serviço sobem só o seu banco (Testcontainers Postgres ou LocalStack).

**Negativas / riscos**
- **Custo:** 3 RDS são a maior parte do custo diário.
- **Dados entre serviços:** relatórios que cruzam serviços exigem composição na API ou dados replicados por evento.
- **Sem `Scan` barato nem consultas ad hoc no Execução:** cada acesso novo exige um GSI e uma revisão da RFC-F4-02. A fila e a outbox usam GSIs com partição única, aceitável no volume de uma oficina.
- **Sem FK e sem unicidade por nome de peça:** o DynamoDB não indexa elementos de lista nem impõe unicidade fora da chave. As regras de unicidade (um serviço por ordem, uma peça por prestação) são do agregado.
- **Snapshots desatualizados:** o snapshot de `placa` na OS pode divergir se o veículo mudar depois, o que é aceito, porque a OS registra o veículo do atendimento.
