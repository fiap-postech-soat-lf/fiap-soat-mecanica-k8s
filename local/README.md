# Ambiente local

Infra para desenvolver os 4 serviços na máquina, com os mesmos nomes de filas e tópicos da AWS (tabela 3.4 do plano da F1):

| Container | Porta | Uso |
|---|---|---|
| `localstack` (4.14.0) | 4566 | SNS, SQS, DynamoDB, Secrets Manager e SSM |
| `postgres-identity` | 5433 | banco `identity` |
| `postgres-os` | 5434 | banco `os` |
| `postgres-billing` | 5435 | banco `billing` |

Os serviços Java **não** rodam no compose. Cada um sobe pela IDE ou com `./mvnw spring-boot:run -Dspring-boot.run.profiles=local`, nas portas 8081 (identity), 8082 (os), 8083 (billing) e 8084 (execucao). Usuário e senha dos Postgres: `postgres`/`postgres`.

## Subir e conferir

```bash
cd /home/rede/git/fase4/fiap-soat-mecanica-k8s
docker compose -f local/docker-compose.yml up -d --wait   # ~1 min: o LocalStack só fica healthy depois do init
local/verificar.sh                                        # OK nas 6 tabelas DynamoDB, 5 filas (+ DLQs), 3 tópicos, 4 assinaturas e nos testes ponta a ponta
```

O `verificar.sh` publica um envelope em `mecanica-execucao-eventos` e confere que ele chega em `mecanica-os-saga-respostas` idêntico, sem o embrulho do SNS. Ele também publica uma `SituacaoOrdemServicoAlterada` e uma `OrdemServicoCancelada` em `mecanica-os-eventos` e confere que só a segunda chega na `mecanica-execucao-os-eventos` (filtro da assinatura, F5-b). Pare o OS e o Execução locais antes, porque eles consomem essas filas.

O LocalStack não guarda estado: a cada `up`, os scripts de `localstack/init/ready.d/` recriam a mensageria (`01-mensageria.sh`) e as tabelas DynamoDB (`02-dynamodb.sh`). Os bancos ficam em volumes nomeados; `docker compose -f local/docker-compose.yml down -v` apaga tudo.

## Token de desenvolvimento

```bash
local/jwt/gerar-chaves-dev.sh                  # uma vez: dev-private.pem e dev-public.pem (ignorados pelo git)
TOKEN=$(local/jwt/gerar-token-dev.sh MECANICO) # CLIENTE | ATENDENTE | MECANICO | ALMOXARIFE [sub]
curl -H "Authorization: Bearer $TOKEN" localhost:8081/clientes
```

O token segue o contrato do Identity (RS256, `kid=mecanica-identity-v1`, `iss`, `aud`, `sub`, `principal_type`, `cargo`, 1 h). O perfil `local` dos serviços lê a chave pública em `../fiap-soat-mecanica-k8s/local/jwt/dev-public.pem`. Com `gerar-chaves-dev.sh --forcar`, o par é trocado e os tokens antigos deixam de valer.

Duas variáveis mudam o token: `CHAVE_PRIVADA=<arquivo>` assina com outra chave (o `scripts/smoke-borda.sh` usa a do Identity, lida do Secrets Manager) e `EMITIDO_HA_SEGUNDOS=<n>` recua o `iat` e o `exp` (`7200` gera um token vencido há 1 h).

## Mensageria

- Filas padrão com `VisibilityTimeout=30`, retenção de 4 dias e redrive para a `-dlq` após 5 recebimentos.
- Assinaturas com `RawMessageDelivery=true`: o corpo na fila é o próprio envelope.
- Para um serviço consumir no perfil `local`, use `app.messaging.consumidor.filas=http://sqs.us-east-1.localhost.localstack.cloud:4566/000000000000/<fila>`.
- A assinatura `mecanica-os-eventos → mecanica-execucao-os-eventos` tem `FilterPolicy {type: [OrdemServicoCancelada]}` (F5-b): o Execução só recebe o cancelamento.

## DynamoDB (Execução)

O `02-dynamodb.sh` cria, com os mesmos nomes, chaves, GSIs e TTL do `infra/dynamodb.tf` do `-execucao` (RFC-F4-02), as 6 tabelas on-demand:

| Tabela | Chave | GSI esparso / TTL |
|---|---|---|
| `execucao-ordens` | `osId` | GSI `fila` (`fila` + `filaOrdem`) |
| `execucao-pecas` | `pecaId` | — |
| `execucao-reservas` | `osId` + `pecaId` | — |
| `execucao-outbox` | `id` | GSI `pendentes` (`pendente` + `criadoEm`); TTL `expiraEm` |
| `execucao-idempotencia` | `messageId` | TTL `expiraEm` |
| `execucao-tempos` | `servicoId` | — |

O script é idempotente (pula a tabela que já existe). O seed das 3 peças é feito pelo próprio Execução (`SeedPecas`) ao subir.

## LocalStack e licença

A `4.14.0` é a última tag 4.x da edição community e roda sem conta. As versões `2026.x` não foram testadas aqui. Se a imagem passar a exigir conta, crie uma conta gratuita e copie `.env.example` para `local/.env` com o `LOCALSTACK_AUTH_TOKEN`. O `.env` é ignorado pelo git.
