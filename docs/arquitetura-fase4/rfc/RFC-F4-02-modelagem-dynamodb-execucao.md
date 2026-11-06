# RFC-F4-02: Modelagem DynamoDB do Execução

- **Status:** Proposto (passa a Aprovado no fim da F5, com o que mudar durante a implementação)
- **Data:** 2026-11-06, escrita antes de qualquer código do Execução
- **Escopo:** `fiap-soat-mecanica-execucao`: `adapters/out/dynamo/**`, `infra/dynamodb.tf` e as tabelas de teste (`TabelasDeTeste`)
- **Base:** [ADR-F4-01](../adr/ADR-F4-01-decomposicao-em-4-servicos.md) (o Execução é dono de diagnóstico, prestações, fila, peças e estoque), [ADR-F4-04](../adr/ADR-F4-04-outbox-consumidor-idempotente.md) (outbox e consumidor idempotente) e [ADR-F4-05](../adr/ADR-F4-05-database-per-service.md) (DynamoDB no Execução)

## Resumo

O Execução guarda seus dados em **6 tabelas DynamoDB on-demand**. A ordem de execução é um documento único, com prestações e alocações aninhadas. O estoque fica materializado em três contadores, e a reserva de N peças é um `TransactWriteItems` condicional: ou reserva todas, ou nenhuma. Toda escrita de negócio vai na mesma transação que a linha da outbox e o registro de idempotência. Dois GSIs esparsos atendem as duas listas ordenadas: a fila de execução e as mensagens pendentes da outbox.

A modelagem parte dos padrões de acesso abaixo, e não das tabelas do monolito (`pecas`, `prestacao_servico` e `alocacao_pecas`, migrations V4, V7 e V8).

## Padrões de acesso

| # | Acesso | Quem usa | Operação |
|---|---|---|---|
| 1 | Ordem por `osId` | todas as rotas `/execucoes/{osId}/**` e os 5 handlers | `GetItem` (`ConsistentRead`) em `execucao-ordens` |
| 2 | Fila de execução, já ordenada por prioridade e data | `GET /execucoes/fila` | `Query` no GSI `fila` (`fila = "ATIVA"`), paginada por `LastEvaluatedKey` |
| 3 | Peça por id; catálogo de peças | `/pecas/**`, alocação, reserva | `GetItem` (`ConsistentRead`) / `Scan` paginado em `execucao-pecas` (dezenas de itens) |
| 4 | Reservar N peças de uma vez, ou nenhuma | `ReservarPecas` | `TransactWriteItems` com um `Update` condicional por peça |
| 5 | Reservas da ordem (para liberar, baixar ou mostrar) | `LiberarReservaPecas`, `IniciarExecucao`, `GET /execucoes/{osId}` | `Query` (`ConsistentRead`) em `execucao-reservas` por `osId` |
| 6 | Mensagens pendentes da outbox, em ordem de criação | `OutboxPublisherDynamo` | `Query` no GSI esparso `pendentes` |
| 7 | Mensagem já processada? | `ProcessadorMensagemDynamo` | `Put` condicional em `execucao-idempotencia`, dentro da transação do handler |
| 8 | Tempo médio por serviço | `GET /execucoes/tempo-medio[?servicoId=]` | `GetItem` / `Scan` em `execucao-tempos` (um item por serviço do catálogo) |

Não há acesso por placa, por status fora da fila nem por intervalo de datas. Se surgir algum, ele entra como GSI novo, por revisão desta RFC.

## Tabelas

Todas `PAY_PER_REQUEST`, sem `deletion_protection` e sem PITR, porque o ambiente é recriado a cada janela.

| Tabela | Chave | Atributos principais | Índice / TTL |
|---|---|---|---|
| `execucao-ordens` | `osId` (S) | `sagaId`, `veiculoId`, `placa`, `status`, `abertaEm`, `diagnosticoConcluidoEm`, `iniciadaEm`, `finalizadaEm`, `motivo`, `prestacoes` (L), `comandosAtendidos` (M), `versao` (N), `fila` e `filaOrdem` (só nas ativas) | GSI `fila` (PK `fila`, SK `filaOrdem`, projeção `ALL`), esparso |
| `execucao-pecas` | `pecaId` (S) | `nome`, `marca`, `valorUnitario` (N), `qtdEstoque`, `qtdReservada`, `qtdDisponivel` (N), `status`, `versao` (N) | — |
| `execucao-reservas` | `osId` (S) + `pecaId` (S) | `quantidade` (N), `status` (`ATIVA`, `BAIXADA`, `LIBERADA`), `reservadaEm`, `atualizadaEm` | — |
| `execucao-outbox` | `id` (S) | `destino`, `tipo`, `envelope` (S, JSON), `criadoEm`, `pendente` (só enquanto não publicada), `reservadoAte` (N), `publicadaEm`, `expiraEm` (N) | GSI `pendentes` (PK `pendente`, SK `criadoEm`, projeção `ALL`), esparso; TTL `expiraEm` |
| `execucao-idempotencia` | `messageId` (S) | `tipo`, `processadaEm`, `expiraEm` (N) | TTL `expiraEm` (7 dias) |
| `execucao-tempos` | `servicoId` (S) | `nomeServico`, `totalMinutos` (N), `amostras` (N) | — |

**Convenções de atributo:**
- Ids são UUIDs em texto. Valores em dinheiro são `N` (`BigDecimal`, nunca `double`).
- Datas são `S` em UTC, com **largura fixa** `yyyy-MM-dd'T'HH:mm:ss.SSS'Z'`. O `Instant.toString()` omite os milissegundos zerados, e aí `…:00Z` fica depois de `…:00.500Z` na ordem de texto. Isso quebraria as chaves de ordenação `filaOrdem` e `criadoEm`.
- `expiraEm` e `reservadoAte` são `N` em segundos epoch: o TTL do DynamoDB exige esse formato, e o lease precisa comparar com `:agora`.
- `status` é palavra reservada do DynamoDB e sempre aparece como `#status` nas expressões.

### Ordem como documento

Cada item de `execucao-ordens` guarda a ordem inteira:

```
prestacoes: [ { id, servicoId, nomeServico, precoMaoDeObra, status, dataInicio, dataFim,
                alocacoes: [ { id, pecaId, descricao, quantidade, valorUnitario, status } ] } ]
comandosAtendidos: { <tipo do comando>: { ids: [messageId, …], resposta: <envelope> } }
```

Todas as leituras do diagnóstico e da execução pegam a ordem inteira, e as regras de unicidade (um serviço por ordem e uma peça por prestação, entre as ativas) ficam no agregado. A alocação guarda uma cópia de `descricao` e `valorUnitario` da peça, porque o `DiagnosticoConcluido` precisa do valor do momento da alocação.

O DynamoDB não indexa elementos de lista. Por isso as rotas de prestação e alocação levam o `osId`: `PATCH /execucoes/{osId}/prestacoes/{id}/inativar`, `POST /execucoes/{osId}/prestacoes/{id}/pecas` e assim por diante (F5-c, em [`rotas.md`](../../contratos/rotas.md)).

`comandosAtendidos` guarda, por tipo de comando, a cadeia de `messageId` já atendidos e a resposta enviada. Um reenvio do OS (com `messageId` novo e `causationId` apontando para um id da cadeia) recebe a mesma resposta, sem efeito de negócio. Um comando fora da cadeia substitui a entrada (nova rodada da Saga).

### Fila de execução (GSI `fila`)

Só as ordens ativas têm os atributos `fila = "ATIVA"` e `filaOrdem = "<prioridade>#<abertaEm>"`:

| Status | Prioridade |
|---|---|
| `EM_EXECUCAO` | 1 |
| `DIAGNOSTICO_CONCLUIDO` | 2 |
| `EM_DIAGNOSTICO` | 3 |
| `FINALIZADA`, `CANCELADA` | fora da fila (`REMOVE fila, filaOrdem`) |

Uma `Query` com `fila = "ATIVA"` devolve a fila já ordenada, como o `listarAtivas` do monolito, sem `Scan` e sem ordenar em memória. Cada mudança de status reescreve `filaOrdem` na mesma escrita da ordem. O `cursor` da rota é o `LastEvaluatedKey` em base64.

### Outbox (GSI `pendentes`)

A linha nasce com `pendente = "1"` na transação de negócio. O `OutboxPublisherDynamo` (a cada 1 s) lê até 25 linhas do GSI, em ordem de `criadoEm`, e para cada uma:
1. reserva a linha com `SET reservadoAte = :ate` e a condição `attribute_exists(pendente) AND (attribute_not_exists(reservadoAte) OR reservadoAte < :agora)`. Se a condição falha, outra réplica já pegou a linha;
2. publica pelo `SnsSqsPublicador`;
3. grava `REMOVE pendente, reservadoAte SET publicadaEm = :agora, expiraEm = :ttl` (1 dia).

A condição do passo 1 vale na tabela base. Por isso uma linha que o GSI ainda mostra, mas que já foi publicada, é descartada sem republicar.

## Estoque materializado

`execucao-pecas` guarda três contadores, com o invariante **`qtdEstoque = qtdDisponivel + qtdReservada`**. Uma condition expression do DynamoDB compara, mas não faz conta: `qtdEstoque - qtdReservada >= :n` não é aceita. Com `qtdDisponivel` gravado, a condição da reserva fica direta.

| Operação | Update expression | Condição |
|---|---|---|
| Reservar `n` | `SET qtdDisponivel = qtdDisponivel - :n, qtdReservada = qtdReservada + :n, versao = versao + :um` | `qtdDisponivel >= :n AND #status = :ativo` |
| Baixar `n` (`IniciarExecucao`) | `SET qtdEstoque = qtdEstoque - :n, qtdReservada = qtdReservada - :n, versao = versao + :um` | `qtdReservada >= :n` |
| Liberar `n` | `SET qtdDisponivel = qtdDisponivel + :n, qtdReservada = qtdReservada - :n, versao = versao + :um` | `qtdReservada >= :n` |
| `PUT /pecas/{id}` (novo estoque `e`) | `SET qtdEstoque = :e, qtdDisponivel = :e - <reservada lida>, versao = versao + :um, …` | `versao = :v AND qtdReservada <= :e` |

As três operações da Saga **incrementam a `versao` sem conferi-la**. Duas reservas de ordens diferentes não disputam a versão: só a condição sobre `qtdDisponivel` decide. Já o `PUT` calcula `qtdDisponivel` a partir da `qtdReservada` que leu, então ele confere a versão: uma reserva entre a leitura e a escrita faz o `PUT` falhar com 409 `CONFLITO_CONCORRENTE`, e o invariante se mantém.

Cada linha de `execucao-reservas` acompanha o movimento da peça na mesma transação:

| Movimento | Escrita na reserva | Condição |
|---|---|---|
| Reservar | `Put` com `status = ATIVA` | `attribute_not_exists(osId) OR #status = :liberada` (uma nova rodada reaproveita a linha liberada; uma `ATIVA` ou `BAIXADA` nunca é sobrescrita) |
| Baixar | `SET #status = :baixada` | `#status = :ativa` |
| Liberar | `SET #status = :liberada` | `#status = :ativa` |

A condição `ATIVA → LIBERADA` impede devolver o estoque duas vezes quando o `LiberarReservaPecas` chega repetido ou junto com o `OrdemServicoCancelada` (que não mexe no estoque).

Antes de montar a transação, as quantidades são **somadas por `pecaId`**: duas prestações podem usar a mesma peça, e uma transação não pode tocar duas vezes o mesmo item (`ValidationException`).

## Transação, idempotência e conflitos

A `TransacaoDynamo` acumula as escritas (`TransactWriteItem`) de um caso de uso ou de um handler e grava tudo num único `TransactWriteItems` no fim. Esse é o papel do `@Transactional` nos serviços SQL. O Enhanced Client só faz o mapeamento (`TableSchema`). As escritas usam a API de baixo nível, porque o Enhanced Client não monta expressões com conta nem `ADD`. Cada tentativa usa um `clientRequestToken` novo.

| Gatilho | Itens na transação |
|---|---|
| `AbrirDiagnostico` | `Put` da ordem (`attribute_not_exists(osId)`) + outbox + idempotência = 3 |
| `ReservarPecas` com estoque (N peças distintas) | N peças + N reservas + ordem + outbox + idempotência = **2N + 3** |
| `ReservarPecas` recusado | ordem + outbox + idempotência = 3 |
| `LiberarReservaPecas` / `IniciarExecucao` (N reservas ativas) | 2N + 3 |
| `OrdemServicoCancelada` | ordem + idempotência = 2 |
| `PATCH …/diagnostico/concluir` (REST) | ordem + outbox = 2 |
| `PATCH …/prestacoes/{id}/finalizar` (REST) | ordem + `ADD` em `execucao-tempos` + outbox (só na última) = até 3 |

Toda escrita na ordem leva `versao = :v` na condição e `versao = versao + :um` no `SET`.

Um `TransactionCanceledException` é lido pelos `CancellationReasons`, na ordem dos itens:

| Motivo | Item | Tradução |
|---|---|---|
| `ConditionalCheckFailed` | idempotência | `MensagemDuplicadaException`: a mensagem é concluída sem efeito |
| `ConditionalCheckFailed` | ordem, peça ou reserva | `ConflitoConcorrenciaException`: o processador repete o handler até 3 vezes, com nova leitura, e depois devolve a mensagem à fila; no REST, 409 |
| `TransactionConflict` | qualquer um | idem |

Na corrida pela última unidade, as duas reservas leem `qtdDisponivel = 1`, e só uma transação passa. A outra cai em conflito, relê o estoque (agora 0) e responde `ReservaPecasRecusada`. Esse é o cenário do `ReservaConcorrenteIT`.

## Limites aceitos

| Limite | Por que é aceitável |
|---|---|
| O GSI `fila` e o GSI `pendentes` têm uma partição só (chave constante) | O volume de uma oficina fica muito abaixo do limite de uma partição (1.000 WCU e 3.000 RCU por segundo) |
| GSIs são eventualmente consistentes | A fila e a outbox podem atrasar ~1 s. A fila é só leitura, e a outbox se protege pela condição na tabela base. Os testes esperam o efeito (Awaitility), nunca um `sleep` |
| 100 itens por `TransactWriteItems` | Com 2N + 3, cabem **48 peças diferentes** numa reserva. Acima disso a `TransacaoDynamo` recusa com 422, o que não acontece numa OS real |
| 400 KB por item | Uma ordem com dezenas de prestações e alocações ocupa poucos KB. A cadeia de `comandosAtendidos` cresce só com os reenvios do OS, que são limitados |
| `Scan` em `execucao-pecas` e `execucao-tempos` | Dezenas de itens, uma página. As tabelas que crescem (ordens, outbox, idempotência) nunca recebem `Scan` |
| Histórico das reservas | Uma nova rodada sobrescreve a linha `LIBERADA` da rodada anterior. Os eventos publicados guardam o histórico da Saga |

## Alternativas consideradas

| Alternativa | Motivo da rejeição |
|---|---|
| Tabela única (*single-table design*) com prefixos `OS#`, `PECA#` | Não há acesso que leia itens de tipos diferentes de uma vez, porque a ordem já é um item só. Seis tabelas deixam o Terraform, os testes e a avaliação mais legíveis |
| Prestações e alocações em tabelas próprias, como no monolito | Cada leitura viraria `Query` em três tabelas, e cada escrita precisaria de transação para manter a unicidade entre itens. A ordem tem poucas dezenas de linhas, então cabe num documento |
| Só `qtdEstoque` e `qtdReservada`, conferindo a versão em toda reserva | A condição não faz conta, então a reserva teria que ler e conferir a `versao`. Duas reservas de peças com estoque sobrando entrariam em conflito à toa |
| Reserva como contador dentro da ordem, sem `execucao-reservas` | A liberação e a baixa precisam saber quanto de cada peça aquela OS reservou e em que estado está. A linha `(osId, pecaId)` com status condicional também é a proteção contra devolução dupla |
| Fila por `Scan` com ordenação em memória | O `Scan` cresce com as ordens finalizadas e lê a tabela inteira a cada chamada |
| DynamoDB Streams no lugar do GSI `pendentes` | Exigiria uma Lambda ou um consumidor KCL a mais no Academy. O publicador agendado reaproveita o `SnsSqsPublicador` e tem a mesma semântica da outbox SQL |
| Tabelas e seed de peças pelo Terraform (`aws_dynamodb_table_item`) | Cada `apply` voltaria o estoque ao valor do seed. O seed fica num `ApplicationRunner` com `Put` condicional |

## Consequências

- O `infra/dynamodb.tf` do Execução e o `TabelasDeTeste` criam as mesmas 6 tabelas e os 2 GSIs. O `TabelasDeTesteTest` confere a lista contra esta RFC, e o `infra/tests` confere nomes, chaves, índices e TTL.
- A variante DynamoDB da mensageria (`TransacaoDynamo`, `OutboxDynamoAdapter`, `OutboxPublisherDynamo`, `ProcessadorMensagemDynamo` e `IdempotenciaDynamo`) fica só no `-execucao` e não volta para o template, porque não há outro serviço DynamoDB.
- A [ADR-F4-04](../adr/ADR-F4-04-outbox-consumidor-idempotente.md) e a [ADR-F4-05](../adr/ADR-F4-05-database-per-service.md) passam a apontar para esta RFC na revisão da F5. O [`convencoes.md`](../../contratos/convencoes.md) ganha a 6ª tabela (`execucao-tempos`).
