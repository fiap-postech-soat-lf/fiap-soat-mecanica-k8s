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
local/verificar.sh                                        # OK nas 4 filas (+ DLQs), 3 tópicos, 3 assinaturas e no teste raw
```

O `verificar.sh` publica um envelope em `mecanica-execucao-eventos` e confere que ele chega em `mecanica-os-saga-respostas` idêntico, sem o embrulho do SNS. Pare o OS local antes, porque ele consome essa fila.

O LocalStack não guarda estado: a cada `up`, o `localstack/init/ready.d/01-mensageria.sh` recria a mensageria. Os bancos ficam em volumes nomeados; `docker compose -f local/docker-compose.yml down -v` apaga tudo.

## Token de desenvolvimento

```bash
local/jwt/gerar-chaves-dev.sh                  # uma vez: dev-private.pem e dev-public.pem (ignorados pelo git)
TOKEN=$(local/jwt/gerar-token-dev.sh MECANICO) # CLIENTE | ATENDENTE | MECANICO | ALMOXARIFE [sub]
curl -H "Authorization: Bearer $TOKEN" localhost:8081/clientes
```

O token segue o contrato do Identity (RS256, `kid=mecanica-identity-v1`, `iss`, `aud`, `sub`, `principal_type`, `cargo`, 1 h). O perfil `local` dos serviços lê a chave pública em `../fiap-soat-mecanica-k8s/local/jwt/dev-public.pem`. Com `gerar-chaves-dev.sh --forcar`, o par é trocado e os tokens antigos deixam de valer.

## Mensageria

- Filas padrão com `VisibilityTimeout=30`, retenção de 4 dias e redrive para a `-dlq` após 5 recebimentos.
- Assinaturas com `RawMessageDelivery=true`: o corpo na fila é o próprio envelope.
- Para um serviço consumir no perfil `local`, use `app.messaging.consumidor.filas=http://sqs.us-east-1.localhost.localstack.cloud:4566/000000000000/<fila>`.
- As tabelas DynamoDB do Execução entram na F5 (RFC-F4-02).

## LocalStack e licença

A `4.14.0` é a última tag 4.x da edição community e roda sem conta. As versões `2026.x` não foram testadas aqui. Se a imagem passar a exigir conta, crie uma conta gratuita e copie `.env.example` para `local/.env` com o `LOCALSTACK_AUTH_TOKEN`. O `.env` é ignorado pelo git.
