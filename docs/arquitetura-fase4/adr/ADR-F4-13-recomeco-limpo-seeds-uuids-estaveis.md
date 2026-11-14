# ADR-F4-13: Recomeço limpo com seeds de UUIDs estáveis

- **Status:** Aceito
- **Data:** 2026-11-14 (decidido no planejamento da Fase 4 e aplicado nas fases F3, F4 e F5)
- **Escopo:** transversal (Identity, OS, Execução)
- **Implementação:** `V5__seed.sql` do Identity, `V6__seed.sql` do OS e `SeedPecas` do Execução

## Contexto

O monolito tinha uma migration de seed (V9) com usuários, clientes, veículos, serviços, peças e ordens de serviço de teste, todos com UUIDs fixos. Esses UUIDs aparecem em testes, em scripts e em requisições de exemplo. Com a decomposição, cada serviço tem o seu banco (ADR-F4-05), e os dados do monolito estão num banco que a Fase 4 não herda.

## Decisão

- **Recomeço limpo:** nenhum dado do monolito é migrado. Cada serviço tem o seu próprio Flyway, com `V1` sempre a mensageria (ADR-F4-04) e as migrations de domínio a partir do `V2`.
- **Seed por serviço, só com o que é dele**, reaproveitando os UUIDs do V9:

  | Serviço | Seed | Conteúdo |
  |---|---|---|
  | Identity | `V5__seed.sql` | 3 funcionários (atendente, mecânico e almoxarife; senha `Senha@123`, só o hash BCrypt), 2 clientes (PF e PJ) e 2 veículos |
  | OS | `V6__seed.sql` | 2 serviços do catálogo. As OS do V9 **não entram**: sem Saga, o Execução e o Billing não as conheceriam |
  | Execução | `SeedPecas` | 3 peças, gravadas por um `ApplicationRunner` |
  | Billing | — | Sem seed: orçamento e pagamento nascem da Saga |

- **Runner condicional no DynamoDB:** o seed das peças usa `PutItem` com condição de inexistência e é ligado por `app.seed.pecas.enabled` (padrão `true`). Não vai para o Terraform, porque cada `apply` devolveria o estoque ao valor inicial; com o `Put` condicional, um estoque já alterado nunca é sobrescrito.
- **UUIDs estáveis:** os mesmos ids valem em todos os ambientes, e os testes, a collection Postman e os scripts de demonstração os usam sem consultar nada (veículo `44444444-…`, serviço `77777777-…`, peça `55555555-…`).
- **Quem cria as OS:** o BDD, o E2E (`api-smoke.mjs`), a demo da Saga e a collection criam as ordens pela API, passando por todos os serviços.

## Alternativas consideradas

| Alternativa | Motivo da rejeição |
|---|---|
| Migrar os dados do monolito para os 4 bancos | Exigiria um ETL por serviço e a reconstrução de estados de Saga que nunca existiram. O projeto é uma demonstração, e o ambiente é efêmero (destruído a cada janela) |
| UUIDs novos a cada serviço | Quebraria os exemplos, os testes e os scripts herdados, e cada correção de exemplo viraria uma busca |
| Manter as OS do V9 no seed do OS | Ficariam sem Saga e sem ordem no Execução, e o histórico delas seria inconsistente com o resto |
| Seed das peças por Terraform (`aws_dynamodb_table_item`) | Cada `apply` repõe o estoque, apagando o efeito das reservas e das baixas |
| Seed pela API, com um script na subida | Dependeria de o ambiente estar completo e de um token; um seed no deploy é mais simples e idempotente |

## Consequências

- Subir o ambiente do zero sempre dá o mesmo conjunto de dados de teste, e o estoque do seed não é reposto numa nova versão do Execução.
- O seed do Identity inclui um hash de senha de teste. Os arquivos de seed são só para ambientes de demonstração e não devem ser usados em produção.
- O E2E cria os seus próprios dados (com um `runId`) e não gasta o estoque do seed, para poder rodar quantas vezes for preciso.
- Os dados de uso do monolito (ordens, pagamentos) são perdidos. É um custo aceito.
