# fiap-soat-mecanica-servicobase

Microsserviço **servicobase** da **Fase 4** da Oficina Mecânica do Braia (Tech Challenge FIAP SOAT).

> 🚧 Gerado a partir do esqueleto `fiap-soat-mecanica-k8s/templates/servico-base/`. As seções com *TODO* são preenchidas na fase do serviço e revisadas na F9.

## Responsabilidade

*TODO*: o que este serviço faz e quais dados são dele.

## Arquitetura

- Spring Boot 3.5, Java 21 (virtual threads), arquitetura hexagonal: `domain/`, `application/`, `adapters/in|out/`, `config/`.
- Autenticação: JWT RS256 emitido pelo Identity, validado aqui também (defesa em profundidade). Públicos só `/actuator/health/**` e o Swagger.
- Mensageria: AWS SDK v2 direto (SNS e SQS), com outbox transacional e consumidor idempotente.
- Observabilidade: logs JSON com `correlationId`, métricas OTLP e agente OpenTelemetry injetado no EKS (Datadog).

*TODO*: diagrama do serviço.

## API

*TODO*: rotas expostas (ver `docs/contratos/rotas.md` no `-k8s`). Swagger: `/servicobase/swagger-ui.html` (via Traefik) ou `/swagger-ui.html` (local).

## Mensagens

*TODO*: eventos publicados e comandos consumidos (contratos em `docs/contratos/`).

## Como rodar localmente

```bash
docker compose -f ../fiap-soat-mecanica-k8s/local/docker-compose.yml up -d
./mvnw spring-boot:run -Dspring-boot.run.profiles=local
curl localhost:8080/actuator/health
```

Token de dev: `../fiap-soat-mecanica-k8s/local/jwt/gerar-token-dev.sh CLIENTE`.

## Testes e qualidade

```bash
./mvnw verify   # unitários + integração (Testcontainers), JaCoCo ≥ 80% de linhas
```

O CI (`ci / build`) roda os testes e a análise no SonarCloud (`fiap-postech-soat-lf_fiap-soat-mecanica-servicobase`) com espera do Quality Gate.

## Deploy

O CD (`servico-cd.yml@v1`) roda após o CI verde na `main`: `terraform apply` do `infra/` → imagem no ECR → ConfigMap/Secret → `kubectl apply` dos manifestos `k8s/` → rollout e smoke do health. Com o EKS desligado, termina verde sem deploy.

## Decisões

ADRs em `docs/adr/`.
