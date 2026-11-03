# Rotas da Fase 4

Base das IngressRoutes do Traefik (`k8s/ingressroute.yaml` de cada serviço, gerado pelo `scripts/novo-servico.sh`) e das rotas do API Gateway no `-auth` (F2).

| Prefixo | Serviço | Authorizer |
|---|---|---|
| `/auth/**` | identity | 🔓 público |
| `/clientes/**`, `/veiculos/**`, `/usuarios/**` | identity | JWT |
| `/ordem-servicos/veiculo/placa/**` | os | 🔓 público (só situação e datas, sem dados pessoais) |
| `/ordem-servicos/**`, `/servicos/**` | os | JWT |
| `/webhooks/mercadopago` | billing | 🔓 público (validado por HMAC `x-signature`) |
| `/orcamentos/**`, `/pagamentos/**` | billing | JWT |
| `/execucoes/**`, `/prestacoes/**`, `/pecas/**`, `/alocacoes/**` | execucao | JWT |
| `/{identity\|os\|billing\|execucao}/actuator/health/**` | o próprio | 🔓 público |
| `/{svc}/swagger-ui/**`, `/{svc}/swagger-ui.html`, `/{svc}/v3/api-docs/**` | o próprio | 🔓 público |

## Como o Traefik encaminha

Cada serviço tem duas regras na IngressRoute:

1. **Prefixos de recurso** (`PathPrefix(`/clientes`) || ...`): o caminho chega ao serviço sem alteração.
2. **`PathPrefix(`/<svc>`)`** com o middleware `StripPrefix`: `/identity/actuator/health` chega como `/actuator/health`. O Traefik envia `X-Forwarded-Prefix`, e o Spring (`server.forward-headers-strategy=framework`) gera os links do Swagger com o prefixo.

O `PathPrefix` do Traefik compara o início do caminho como texto. Por isso nenhum prefixo de recurso pode começar com outro de outro serviço (por exemplo, `/os...` colidiria com a regra `/os` do OS). Uma rota nova entra nesta tabela e no `novo-servico.sh` antes de ir para o código.

No serviço, as rotas públicas são só health, Swagger e `/error` (`SecurityConfig`). As rotas marcadas como públicas acima ficam abertas **no Authorizer**. No serviço, elas são liberadas pela própria configuração de segurança de cada um, a partir da F3.
