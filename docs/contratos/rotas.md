# Rotas da Fase 4

Base das IngressRoutes do Traefik (`k8s/ingressroute.yaml` de cada serviço, gerado pelo `scripts/novo-servico.sh`) e das rotas do API Gateway no `-auth` (`infra/api.tf`).

| Prefixo | Serviço | Authorizer |
|---|---|---|
| `POST /auth/login`, `POST /auth/cpf` | identity | 🔓 público |
| `/auth/**` (demais), `/clientes/**`, `/veiculos/**`, `/usuarios/**` | identity | JWT |
| `GET /ordem-servicos/veiculo/placa/{placa}` | os | 🔓 público (só situação e datas, sem dados pessoais) |
| `/ordem-servicos/**`, `/servicos/**` | os | JWT (perfis na seção abaixo) |
| `POST /webhooks/mercadopago` | billing | 🔓 público (validado por HMAC `x-signature`) |
| `/orcamentos/**`, `/pagamentos/**` | billing | JWT |
| `/execucoes/**`, `/prestacoes/**`, `/pecas/**`, `/alocacoes/**` | execucao | JWT |
| `GET /{identity\|os\|billing\|execucao}/actuator/health/**` | o próprio | 🔓 público |
| `GET /{svc}/swagger-ui/**`, `/{svc}/swagger-ui.html`, `/{svc}/v3/api-docs/**` | o próprio | 🔓 público |
| `/health-echo` | `mecanica-echo` (`traefik/whoami`, só no `-k8s`) | JWT (diagnóstico da borda: devolve os headers recebidos) |

## Rotas e perfis do OS

O perfil é verificado pelo próprio OS (`ROLE_<tipo>` e `ROLE_<cargo>` do JWT); o API Gateway só valida o token.

| Rota | Perfil |
|---|---|
| `POST /ordem-servicos` (`{veiculoId, observacao}` → 201 `RECEBIDA`, com `Location`) | ATENDENTE ou MECANICO |
| `GET /ordem-servicos?page&size`, `GET /ordem-servicos/{id}`, `GET /ordem-servicos/{id}/historico` | ATENDENTE ou MECANICO |
| `PATCH /ordem-servicos/{id}/cancelar` (`{motivo?}`) | ATENDENTE ou MECANICO |
| `PATCH /ordem-servicos/{id}/revisar-orcamento` (`{motivo?}`) | ATENDENTE ou MECANICO |
| `GET /ordem-servicos/minhas` | CLIENTE (`cliente_id = sub`) |
| 🔓 `GET /ordem-servicos/veiculo/placa/{placa}` | público; devolve só `situacao` e as datas, sem `id`, `clienteId`, valores nem observação |
| `POST /servicos`, `PUT /servicos/{id}`, `PATCH /servicos/{id}/ativar`, `PATCH /servicos/{id}/inativar` | MECANICO |
| `GET /servicos/{id}`, `GET /servicos` (`?incluirInativos=true`) | MECANICO (o Execução repassa o JWT do mecânico na F5) |
| 🔓 `/actuator/health/**`, Swagger, `/error` | público |

`GET /ordem-servicos/{id}` devolve também `clienteId`, `placa`, `sagaId`, `sagaStatus`, `passoAtual`, `orcamentoId` e `valorTotal`.

Erros próprios do OS (`ErrorResponse`):

| Situação | Status | Código |
|---|---|---|
| Veículo inexistente ou inativo | 422 | `VEICULO_INVALIDO` |
| Identity fora do ar (retries esgotados) | 503 | `IDENTITY_INDISPONIVEL` |
| Identity recusou o token repassado | 502 | `INTEGRACAO_IDENTITY` |
| Transição inválida (por exemplo, cancelar uma OS `EM_EXECUCAO`, ou depois de `OrcamentoAprovado`) | 422 | regra de negócio |
| Conflito de versão | 409 | `CONFLITO_CONCORRENTE` (o cliente repete a operação) |

Saíram do controller do monolito e passaram a ser feitos por evento da Saga, ou foram para outro serviço: `POST /abrir`, `iniciar-execucao`, `enviar-para-aguardar-aprovacao`, `pagar` (Saga), `aprovar-orcamento` e `recusar-orcamento` (Billing) e `tempo-medio` (Execução).

## Chamadas entre serviços

Quando um serviço chama outro por REST, ele **repassa o JWT de quem chamou** (o header `Authorization` da requisição em andamento). Não existe token de serviço: o chamado valida o mesmo token e aplica o seu próprio perfil (F3-a).

| Chamada | Rota chamada | Perfil aceito |
|---|---|---|
| OS → Identity | `GET /veiculos/{id}` | **ATENDENTE ou MECANICO** (os dois cargos que abrem OS) |
| Execução → OS (F5) | `GET /servicos/{id}` | MECANICO |

## Como o API Gateway encaminha

- As rotas públicas são **explícitas** (método + caminho): as 4 de negócio acima e 6 de health/Swagger por serviço, 28 no total. Não existe `/auth/**` público: qualquer outro caminho sob `/auth` cai no fallback protegido.
- Todo o resto cai em `ANY /{proxy+}`, com o Lambda Authorizer. O HTTP API escolhe a rota mais específica, então o fallback só pega o que nenhuma rota pública casou.
- Duas integrações `HTTP_PROXY` para o NLB, as duas repassando o caminho e `x-correlation-id = $context.requestId`:
  - `publica` **remove** os `x-user-*` que vierem do cliente;
  - `protegida` preenche `x-user-sub`, `x-user-principal-type` e `x-user-cargo` com o contexto do authorizer.
- Semântica do authorizer em [jwt.md](jwt.md#authorizer-na-borda): sem token **401**, token inválido **403**.

## Como o Traefik encaminha

Cada serviço tem duas regras na IngressRoute:

1. **Prefixos de recurso** (`PathPrefix(`/clientes`) || ...`): o caminho chega ao serviço sem alteração.
2. **`PathPrefix(`/<svc>`)`** com o middleware `StripPrefix`: `/identity/actuator/health` chega como `/actuator/health`. O Traefik envia `X-Forwarded-Prefix`, e o Spring (`server.forward-headers-strategy=framework`) gera os links do Swagger com o prefixo.

O `PathPrefix` do Traefik compara o início do caminho como texto. Por isso nenhum prefixo de recurso pode começar com outro de outro serviço (por exemplo, `/os...` colidiria com a regra `/os` do OS). Uma rota nova entra nesta tabela e no `novo-servico.sh` antes de ir para o código.

No serviço, as rotas públicas são só health, Swagger e `/error` (`SecurityConfig`). As rotas marcadas como públicas acima ficam abertas **no Authorizer**. No serviço, elas são liberadas pela própria configuração de segurança de cada um, a partir da F3.

## NLB público

O NLB (`mecanica-nlb`, porta 80) é público, porque o HTTP API alcança o Traefik por HTTP sem VPC Link (ADR-F4-06). Um acesso direto ao NLB **pula o authorizer** e permite forjar os headers `x-user-*`. É por isso que cada serviço valida o JWT por conta própria e nunca autentica pelos `x-user-*` (defesa em profundidade): sem token, o serviço responde **401** mesmo com `x-user-sub` forjado.
