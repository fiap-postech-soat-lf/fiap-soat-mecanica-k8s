# ADR-F4-09: REST síncrono entre serviços, com timeout, retry e repasse do JWT

- **Status:** Aceito
- **Data:** 2026-11-05
- **Escopo:** OS (cliente do Identity) e, na F5, Execução (cliente do OS)
- **Implementação:** `fiap-soat-mecanica-os` (`adapters/out/rest/identity/`: `IdentityClient`, `IdentityClientConfig`, `RepasseAutorizacaoInterceptor`); `RestClientConfig` do esqueleto (timeout)

## Contexto

Quase tudo entre os serviços é assíncrono (Saga, ADR-F4-02). Duas consultas, porém, precisam de resposta na hora:

- **OS → Identity:** ao abrir uma OS, é preciso saber se o veículo existe e está ativo, e qual é o cliente e a placa (`GET /veiculos/{id}`). Se falhar, a OS nem nasce.
- **Execução → OS** (F5): o mecânico monta o diagnóstico com o catálogo de serviços (`GET /servicos/{id}`).

Era preciso decidir como autenticar essas chamadas e o que fazer quando o chamado está lento ou fora do ar.

## Decisão

- **Só duas chamadas síncronas** (a de veículo e a de catálogo). Todo o resto é mensagem.
- **Timeout de 2 s** (o `RestClientConfig` do esqueleto) e **retry programático** com `resilience4j-retry` (sem AOP): 3 tentativas, backoff exponencial de 200 ms × 2, **só** em erro de I/O, timeout ou 5xx. **Sem circuit breaker** (corte 3): com 2 chamadas e poucas réplicas, ele não traria ganho que justificasse o estado extra.
- **Repasse do JWT (F3-a, F4-b):** o serviço chamado recebe o **mesmo token de quem chamou**. Não existe token de serviço. O `RepasseAutorizacaoInterceptor` (`ClientHttpRequestInterceptor`) copia o header `Authorization` da requisição em andamento (`RequestContextHolder`). Ele é aplicado **só** ao `RestClient` do `IdentityClient`, não ao `RestClientCustomizer` global, e **não entra no template**.
- **Por que não global:** um interceptor global vazaria o token do usuário para qualquer destino de um `RestClient` (por exemplo, uma chamada externa no Billing). Fora do template, também não obriga a mexer nos 4 repositórios. Na F5, o Execução copia a classe (um arquivo e um teste).
- **Mapeamento de erros** (a Saga não começa em nenhum deles, passo 1 da ADR-F4-02):

  | Resposta do Identity | Resposta do OS |
  |---|---|
  | 404, ou veículo inativo | **422** `VEICULO_INVALIDO` |
  | Retries esgotados (I/O, timeout ou 5xx) | **503** `IDENTITY_INDISPONIVEL` |
  | 401 ou 403 (sem retry) | **502** `INTEGRACAO_IDENTITY` |

  O 401/403 não deveria ocorrer, porque a chave pública é a mesma nos dois serviços. Se ocorrer, indica configuração errada, e repetir não resolve.
- **Perfis aceitos pelo chamado:** `GET /veiculos/{id}` aceita ATENDENTE ou MECANICO (os cargos que abrem OS); `GET /servicos/{id}` aceita MECANICO. A tabela está em `docs/contratos/rotas.md`.
- A URL base do Identity é o DNS do cluster (`http://mecanica-identity.mecanica.svc.cluster.local:8080`), sem passar pelo API Gateway.
- O `X-Correlation-Id` acompanha a chamada (`CorrelationIdInterceptor`).

## Alternativas consideradas

| Alternativa | Motivo da rejeição |
|---|---|
| Token de serviço (client credentials) | Mais um segredo para emitir, guardar e rotacionar, e o chamado perderia a identidade do usuário (o log e o perfil deixariam de refletir quem agiu) |
| Interceptor global de repasse | Vaza o token de usuário para qualquer destino do `RestClient` |
| Copiar o veículo para o OS por evento | Exigiria uma réplica de dados do Identity e tratar a consistência; o snapshot (`clienteId`, `placa`) na abertura já cobre o que o OS precisa |
| Circuit breaker (Resilience4j) | Fora do escopo (corte 3): duas chamadas, timeout curto e o retry limitado bastam para a demonstração |
| Resilience4j com AOP (`@Retry`) | Esconde o comportamento em anotações e exige o starter do AOP; o uso programático fica visível e testável |

## Consequências

**Positivas**
- A abertura da OS falha rápido e de forma explicada (422, 503 ou 502), sem deixar OS ou Saga pela metade, porque nada é gravado antes da consulta.
- A identidade do usuário chega ao Identity e aparece no log dele (`sub` do atendente).
- O comportamento é coberto por teste com WireMock: 503, 503, 200 → sucesso; 3× 503 → 503; atraso de 3 s → timeout e retry; 401 sem retry; o header `Authorization` recebido é igual ao original.

**Negativas / riscos**
- O pior caso de uma abertura é de ≈ 6,6 s (3 tentativas de 2 s mais os backoffs). Aceitável para uma abertura de OS, mas inadequado para um endpoint de alta frequência.
- Se o Identity cair, nenhuma OS nova abre (não há cache). É o comportamento escolhido: sem veículo validado, a OS não existe.
- O repasse só funciona dentro de uma requisição HTTP. Uma chamada feita por um handler de mensagem não tem token para repassar; hoje não há chamada assim.
