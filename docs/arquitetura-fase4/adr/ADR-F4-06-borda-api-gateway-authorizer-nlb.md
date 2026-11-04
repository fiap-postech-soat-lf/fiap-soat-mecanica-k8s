# ADR-F4-06: Borda com HTTP API, Lambda Authorizer e NLB público até o Traefik

- **Status:** Aceito
- **Data:** 2026-11-04 (implementado na F2 e validado na janela de integração do D7)
- **Escopo:** `-auth` (API Gateway e authorizer), `-k8s` (NLB e Traefik) e os 4 serviços (rotas e validação do JWT)
- **Implementação:** `fiap-soat-mecanica-auth/infra/api.tf` e `lambda.tf`; `fiap-soat-mecanica-k8s/terraform/nlb.tf` e `traefik.tf`; `k8s/echo.yaml` (diagnóstico); `scripts/smoke-borda.sh`
- **Substitui:** ADR-003 do `fiap-soat-mecanica-api-k8s` do grupo (Traefik como API Gateway dentro do cluster)

## Contexto

A Fase 4 exige um API Gateway na frente dos serviços, com autenticação por JWT nas rotas protegidas. Na Fase 3 do grupo, o Traefik fazia esse papel exposto em `NodePort` (ADR-003), com o IP do node como endereço. Aquela ADR já previa trocar por um endereço estável se o API Gateway da AWS precisasse de um destino fixo.

Restrições:
- O Academy não deixa criar IAM roles. A Lambda usa a `LabRole`, e qualquer recurso que dependa de uma service-linked role nova pode ser bloqueado.
- O ambiente é destruído e recriado a cada janela. O destino da borda precisa ser descoberto, não configurado à mão (ADR-F4-14).
- O token é emitido pelo Identity (RS256, ADR-F4-07). O `-auth` não pode depender da chave privada.
- Cada load balancer custa por hora (RFC-F4-03).

## Decisão

```
cliente ──HTTPS──▶ HTTP API mecanica-api ($default)
                     ├─ rota pública ─────────▶ integração "publica"   ─┐
                     └─ ANY /{proxy+} ─ authorizer mecanica-jwt ─▶ "protegida" ─┤
                                                                    HTTP ▼
                                         NLB mecanica-nlb :80 (público, SG próprio)
                                                                    TCP ▼
                                         nodes :30090 (só a partir do SG do NLB)
                                                                        ▼
                                         Traefik (NodePort) ─ IngressRoute ─▶ serviço
```

**API Gateway (`-auth`)**
- HTTP API `mecanica-api`, stage `$default` com `auto_deploy`, throttling (burst 50, rate 25) e access log em JSON (`requestId`, `routeKey`, `status`, `authorizerError`, `integrationErrorMessage`, `integrationLatency`) em `/aws/apigateway/mecanica-api` (7 dias).
- **Authorizer `mecanica-jwt`:** `REQUEST`, payload 2.0, resposta simples (`isAuthorized`), identity source `$request.header.Authorization` e cache de 300 s por esse header.
- **Lambda `mecanica-authorizer`:** Java 21, 512 MB, fora da VPC, role `LabRole`. Aplica as regras do `JwtTokenValidator` dos serviços sem Spring (`alg` exatamente `RS256`, `iss`, `aud`, `exp` com 30 s, `sub` UUID, `principal_type`, `cargo`). A chave pública vem do SSM `/mecanica/identity/jwt-public-key` como variável de ambiente (ADR-F4-07). Devolve o contexto `{sub, principalType, cargo}`.
- **Duas integrações `HTTP_PROXY`** para `http://<nlb-dns>` (lido do SSM `/mecanica/k8s/nlb-dns`), ambas com `overwrite:path = $request.path` e `x-correlation-id = $context.requestId`:
  - `publica` **remove** os `x-user-*` que vierem do cliente;
  - `protegida` **sobrescreve** os `x-user-*` com `$context.authorizer.*`.
- **Rotas públicas explícitas (28):** `POST /auth/login`, `POST /auth/cpf`, `GET /ordem-servicos/veiculo/placa/{placa}` e `POST /webhooks/mercadopago`, mais `actuator/health`, `swagger-ui` e `v3/api-docs` de cada um dos 4 serviços. Todo o resto cai em `ANY /{proxy+}`, com o authorizer. O HTTP API escolhe a rota mais específica, então o fallback não captura as públicas.

**Semântica das respostas**

| Situação | Resposta | Quem responde |
|---|---|---|
| Sem header `Authorization` | **401** `Unauthorized` | API Gateway, sem invocar a Lambda |
| Token inválido (assinatura, `alg`, `iss`, `aud`, `exp`, claims) ou sem `Bearer` | **403** `Forbidden` | API Gateway, com `isAuthorized=false`. A Lambda loga `autorizacao_negada` com o `motivo`, nunca o token |
| Token válido | resposta do serviço | integração `protegida` → NLB → Traefik |

**NLB (`-k8s`)**
- NLB `mecanica-nlb` público, listener TCP 80 → target group `mecanica-traefik` (instâncias, porta 30090), anexado ao ASG do node group por `aws_autoscaling_attachment`, com cross-zone ligado.
- O NLB tem **security group próprio** (80 aberto para a internet). O SG do cluster só aceita a 30090 **a partir do SG do NLB**, então os nodes não expõem o NodePort.
- O Traefik continua em `NodePort` 30090 (chart fixado na 42.3.0, Traefik v3.7.17), mas deixa de ser o gateway: só roteia (`IngressRoute` + `StripPrefix` por serviço).

## Alternativas consideradas

| Alternativa | Motivo da rejeição |
|---|---|
| **HTTP API + VPC Link → NLB interno** | Tiraria o NLB da internet e o JWT do trecho em HTTP aberto. Exige a service-linked role `AWSServiceRoleForAPIGateway`, que o Academy pode não deixar criar, e o VPC Link leva vários minutos para criar e destruir em cada janela. É a primeira opção se o projeto sair do Academy |
| **REST API (v1) com authorizer** | Mais caro por requisição e mais verboso em Terraform. O HTTP API tem authorizer Lambda com resposta simples e cache, que é o que o projeto precisa |
| **ALB na frente do Traefik** | Custa mais que o NLB (LCU) e não acrescenta nada, porque o roteamento L7 já é do Traefik. O AWS Load Balancer Controller exigiria IRSA (role nova), o que não é permitido |
| **Ingress do Kubernetes como gateway (ADR-003 do grupo)** | O Traefik não valida o JWT RS256 sem plugin, e o enunciado da Fase 4 pede API Gateway com Lambda. O endereço `NodePort` muda quando um node é trocado |
| **`/auth/**` como rota pública** | Abriria qualquer rota futura do Identity sob `/auth`. Só os dois logins são públicos |
| **Authorizer `JWT` nativo do HTTP API** | Exige um issuer OIDC com JWKS publicado por HTTPS. O Identity não publica JWKS, e as regras de `principal_type` e `cargo` precisariam de código mesmo assim |

## Consequências

**Positivas**
- **Destino estável:** o DNS do NLB vai para o SSM, e o `-auth` o lê no apply. Trocar node ou recriar o cluster não muda nada na borda além de reaplicar o `-auth`, o que o `subir-ambiente.sh` já faz na ordem certa.
- **Identidade sem falsificação na borda:** um cliente não consegue injetar `x-user-*`, porque a rota pública os remove e a protegida os sobrescreve.
- **Diagnóstico:** o `whoami` em `/health-echo` devolve os headers recebidos, o que prova o que o API Gateway injetou. O `smoke-borda.sh` verifica 401, 403, 200 e a cadeia até o Identity em cada janela.
- **Sem IAM novo:** Lambda com `LabRole` e permissão de invocação restrita ao authorizer (`source_arn`).

**Trade-offs aceitos**
- **JWT em HTTP entre o API Gateway e o NLB.** O trecho cliente → API Gateway é HTTPS, mas o API Gateway → NLB é HTTP. O token trafega sem TLS nesse trecho, dentro da rede da AWS. Mitigação: TTL do token de 1 h e chave nova a cada janela. A correção é o VPC Link (alternativas).
- **NLB alcançável sem o API Gateway.** Quem descobrir o DNS do NLB chega ao Traefik sem passar pelo authorizer. Mitigação: **cada serviço valida o JWT de novo** (`JwtAuthenticationFilter`) e não autentica pelos `x-user-*`. A verificação 9 do DoD da F2 prova isso (`GET http://<nlb>/clientes` com `x-user-sub` forjado → 401 do Identity).
- **Cache de 300 s.** Um token que expira dentro da janela do cache ainda passa pela borda por até 5 min. O serviço valida o `exp` de novo.
- **Cold start Java** do authorizer (1–2 s na primeira requisição de cada container). O cache absorve a maior parte. Se o p95 incomodar, o próximo passo é 1024 MB. O SnapStart fica fora, porque exige versões e alias.
- **Trocar a chave exige reaplicar o `-auth`**, porque a chave pública é variável de ambiente da Lambda (ADR-F4-07).
