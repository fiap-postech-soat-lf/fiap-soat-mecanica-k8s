# RFC-F4-01: Integração com o Mercado Pago (Checkout Pro)

- **Status:** Aprovado (F6, 2026-11-07). A prova no EKS (APRO e OTHE) é registrada na 11.2 da F6
- **Data:** 2026-11-07, escrita antes de qualquer código do Mercado Pago no Billing. Revisada em 2026-11-07 com a implementação (T04 e T06)
- **Escopo:** `fiap-soat-mecanica-billing`: `adapters/out/rest/mercadopago/**`, `adapters/in/web/webhook/**`, `infra/` (secrets) e a configuração do webhook na aplicação `mecanica-fase4`
- **Base:** [ADR-F4-01](../adr/ADR-F4-01-decomposicao-em-4-servicos.md) (o Billing é dono de orçamento e pagamento), [ADR-F4-02](../adr/ADR-F4-02-saga-orquestrada.md) (cobrança só para a frente depois do pivô), [ADR-F4-04](../adr/ADR-F4-04-outbox-consumidor-idempotente.md) (outbox e idempotência) e [ADR-F4-09](../adr/ADR-F4-09-rest-sincrono-resilience4j.md) (REST síncrono com retry)

## Resumo

O Billing cobra pelo **Checkout Pro** do Mercado Pago, no sandbox. Ele cria uma preferência de pagamento por OS e entrega o link ao cliente. A página de pagamento é do Mercado Pago, então nenhum dado de cartão passa pelo Billing. O resultado chega por **webhook**: o Billing valida o `x-signature`, grava a notificação e responde 200 na hora; depois consulta o status no Mercado Pago (nunca confia no corpo) e emite `PagamentoConfirmado` ou `PagamentoRecusado`.

Os dois cenários do DoD da F6 são reproduzíveis com os cartões de teste: **APRO** (titular aprovado) gera `PagamentoConfirmado`, e **OTHE** (recusado por erro geral) gera `PagamentoRecusado`.

## Opções

| Opção | Aprovado e recusado controláveis? | Dado de cartão no Billing? | Esforço | Veredito |
|---|---|---|---|---|
| **Checkout Pro** (redirecionamento) | Sim, pelo nome do titular (APRO, OTHE) | Não | Baixo: uma preferência e um link | **Recomendada** |
| PIX (Checkout API) | Não: o PIX de teste não tem um "recusado" controlável | Não | Médio: QR code e expiração | Rejeitada: não prova o `PagamentoRecusado` |
| Checkout Bricks | Sim | O formulário é embutido; o token do cartão passa pelo front | Alto: exige um front, que a Fase 4 não tem | Rejeitada: sem front no escopo |

## Integração

O Billing usa um **`RestClient` próprio** (`MercadoPagoClient`), e não o `sdk-java`. O SDK guarda o token numa configuração estática global e não deixa trocar a URL base com facilidade, o que atrapalha o WireMock. A API usada se resume a duas chamadas:

| Chamada | Para quê | Detalhes |
|---|---|---|
| `POST /checkout/preferences` | Criar a cobrança | Um item (`title = "Ordem de serviço <osId curto>"`, `quantity = 1`, `currency_id = BRL`, `unit_price` = valor do orçamento aprovado), `external_reference = pagamentoId`, **sem `notification_url`**. Header `X-Idempotency-Key = pagamentoId` |
| `GET /v1/payments/{id}` | Consultar o status real | Devolve `status`, `status_detail` e `external_reference` |

Regras do cliente:
- base URL configurável (WireMock nos testes), `Authorization: Bearer <MP_ACCESS_TOKEN>`, timeout de 5 s;
- retry programático do `resilience4j-retry` (3 tentativas, 500 ms × 2), só em I/O, timeout ou 5xx. Um 4xx não repete;
- o token do usuário **nunca** sai para o Mercado Pago: não há `RepasseAutorizacaoInterceptor`;
- o link entregue é o `init_point` (`sandbox_init_point` fica como alternativa, por configuração).

A criação do `Pagamento` e da preferência acontece **dentro da transação do handler** de `SolicitarPagamento`. Se o Mercado Pago falhar, a transação é desfeita, a mensagem volta à fila e o OS reenvia depois. O contrato não tem um "cobrança falhou", e depois do pivô não há compensação. Uma preferência criada sem commit fica órfã no Mercado Pago, o que é inofensivo: ninguém recebe o link.

### Nova cobrança

Um pagamento `RECUSADO` pode ser substituído por `POST /pagamentos/{osId}/nova-cobranca` (ATENDENTE). O vigente vira `SUBSTITUIDO`, nasce um novo `PENDENTE` com outra preferência, e sai um `CobrancaCriada` (o OS só atualiza o `pagamentoId`). Há **um pagamento vigente por OS**, garantido por índice único parcial.

No Checkout Pro, uma nova tentativa no mesmo link gera outro `payment.id` com a mesma `external_reference`. Por isso uma aprovação no vigente `RECUSADO` é aceita. Uma aprovação num pagamento `SUBSTITUIDO` é **ignorada**, com log `pagamento_em_cobranca_substituida` e a métrica `pagamento.substituido_aprovado`, porque o OS não confere o `pagamentoId` do `PagamentoConfirmado` e só o vigente pode gerar evento.

## Webhook

`POST /webhooks/mercadopago` é público (o API Gateway usa a integração `publica`) e protegido por assinatura:

1. `x-signature` = `ts=<ts>,v1=<hex>`. Faltou `ts` ou `v1` → 401;
2. manifesto `id:<data.id>;request-id:<x-request-id>;ts:<ts>;`, com `data.id` do query param (o corpo é a alternativa) em minúsculas, e uma parte ausente sai do manifesto;
3. `HMAC-SHA256(MP_WEBHOOK_SECRET, manifesto)` em hex, comparado com `v1` em tempo constante (`MessageDigest.isEqual`);
4. assinatura ausente ou inválida, ou segredo ausente → **401 sem gravar nada** (o Mercado Pago repete a notificação).

Com a assinatura válida, o `type` diferente de `payment` responde 200 sem efeito. Senão, o Billing grava em `webhook_eventos` (`PENDENTE`) e responde **200 na hora**. Um scheduler (2 s, `FOR UPDATE SKIP LOCKED`, até 3 réplicas) processa cada evento em uma transação:

1. consulta `GET /v1/payments/{id}`. O status **nunca** vem do corpo da notificação, porque o corpo pode ser forjado por quem conhece a URL e o `data.id`;
2. se `(mp_payment_id, status)` já está em `mp_status_aplicado`, marca `PROCESSADO` sem efeito;
3. senão, aplica o resultado no pagamento da `external_reference`, insere em `mp_status_aplicado` e grava o evento na outbox, tudo na mesma transação.

| Status no Mercado Pago | Efeito |
|---|---|
| `approved` | `APROVADO` e `PagamentoConfirmado` |
| `rejected`, `cancelled` | `RECUSADO` e `PagamentoRecusado` (`motivo` = `status_detail`) |
| `pending`, `in_process`, `authorized` | nenhum; espera a próxima notificação |
| qualquer outro, ou `external_reference` desconhecida | `IGNORADO`, com log |

**Idempotência.** O Mercado Pago notifica várias vezes o mesmo pagamento (`payment.created`, `payment.updated`) e repete quando não recebe 200. A chave `(payment.id, status)` em `mp_status_aplicado` (PK) garante um efeito só por mudança de status. Falha do Mercado Pago na consulta → nova tentativa com backoff 2^n s, até 5; esgotadas, o evento vai para `ERRO` e a métrica `mercadopago.erros` sobe.

### Onde o webhook é configurado

O webhook fica na **aplicação dona do token** (`mecanica-fase4`, conta real, plano B do T07 da F1), e não em `notification_url` na preferência. O segredo da assinatura é o da aplicação.

O API Gateway é recriado a cada subida do ambiente, e a URL muda. Em toda janela que use pagamento (F6, F7 e a gravação da F9), depois do CD do `-auth`, a URL `<api-url>/webhooks/mercadopago` é gravada como `callback` **e** `callback_sandbox` (tópico `payment`) pelo MCP `save_webhook` do plugin `mercadopago` (ou pelo painel). A entrega é conferida com o `notifications_history`. Depois de gravar, confere-se que o segredo da assinatura **não mudou**: se mudar, o `MP_WEBHOOK_SECRET` fica desatualizado e todo webhook responde 401.

## Segredos

`MP_ACCESS_TOKEN` e `MP_WEBHOOK_SECRET` entram no `infra/` do Billing como variáveis `sensitive` **sem default** (sem elas, o `plan` falha), viram os secrets `mercadopago-access-token` e `mercadopago-webhook-secret` (`recovery_window_in_days = 0`) e chegam ao pod pelo `app_secrets`. O CD já passa os valores pelas variáveis `TF_VAR_*`. Nada é versionado. Localmente, os valores só existem como variáveis de ambiente da sessão.

Sem token, o Billing sobe, loga `mercadopago_token_ausente` e as cobranças falham (a mensagem vai para a DLQ depois de 5 recebimentos). Sem segredo, o webhook responde 401.

## Limites aceitos

| Limite | Por que é aceitável |
|---|---|
| Sandbox apenas, com credenciais de teste | O projeto não movimenta dinheiro. As credenciais de teste agem em nome do vendedor de teste |
| Nenhum estorno automático | O pagamento aprovado numa cobrança `SUBSTITUIDO` é tratado à mão (métrica `pagamento.substituido_aprovado`). É um caso raro: o cliente teria de pagar o link antigo depois de uma nova cobrança |
| O webhook não alcança a máquina local | O Mercado Pago só chama uma URL pública. A prova real é no EKS (janela da F6). Nos testes, o webhook é exercitado com requisições assinadas e o Mercado Pago com WireMock |
| URL do webhook regravada a cada janela | O API Gateway é recriado a cada subida. É um passo do roteiro da janela (F6-j), conferido pelo `notifications_history` |
| A criação da preferência fica dentro da transação do handler | Se o commit falhar depois da chamada, sobra uma preferência órfã. Ninguém recebe o link, então não há efeito |
| Webhook com latência de segundos | A resposta 200 é imediata, mas o efeito sai até ~2 s depois (scheduler). A demo e os testes esperam o efeito, nunca um `sleep` fixo |

## Alternativas consideradas

| Alternativa | Motivo da rejeição |
|---|---|
| `sdk-java` do Mercado Pago | Configuração estática global do token e URL base difícil de trocar nos testes. Só duas chamadas são usadas |
| `notification_url` em cada preferência | Cada URL seria específica da janela e iria no corpo da preferência. A configuração na aplicação já cobre todas as preferências com um único passo por janela |
| Confiar no status do corpo da notificação | O corpo não é autenticado além do `x-signature`, e o Mercado Pago recomenda consultar o pagamento. A consulta também resolve a ordem trocada de notificações |
| Processar o webhook dentro da requisição | O Mercado Pago repete a notificação se a resposta demorar ou falhar. Gravar e responder 200 desacopla o recebimento da consulta e permite o retry com backoff |
| Idempotência só por `payment.id` | Um mesmo pagamento passa por mais de um status (`pending` → `approved`). A chave `(payment.id, status)` aplica cada mudança uma vez |
| Compensar (estornar) quando a cobrança falha | Depois do pivô (`IniciarExecucao`), a Saga só recupera para frente (ADR-F4-02), e o contrato não tem um "cobrança falhou" |

## Consequências

- O Billing ganha as tabelas `webhook_eventos` e `mp_status_aplicado` (migration V4) e o par `MercadoPagoClient` / `GatewayPagamentoPort`, trocável por um fake nos testes.
- A [ADR-F4-04](../adr/ADR-F4-04-outbox-consumidor-idempotente.md) ganha, na revisão da F6, a idempotência por chave de negócio em SQL (`comando_atendido`) e a do webhook por `(payment.id, status)`. A [ADR-F4-02](../adr/ADR-F4-02-saga-orquestrada.md) passa a registrar o TTL do orçamento no Billing e a cobrança só para a frente.
- Toda janela que use pagamento inclui o passo de gravar a URL do webhook e conferir o segredo.
- **Aceite:** as seções de orçamento, cobrança, webhook e `infra/` da F6 não contradizem esta RFC. A RFC passou a **Aprovado** no T08, com a seção abaixo.

## O que mudou na implementação

Nenhuma decisão da RFC foi revertida. A implementação (PRs #7 e #9 do `-billing`) acrescentou três detalhes:

| Detalhe | Por quê |
|---|---|
| O `RestClient` do Mercado Pago é fixado em **HTTP/1.1** | O cliente HTTP do JDK tenta o upgrade `h2c` em requisições sem TLS, e isso quebrava o `POST` contra o WireMock dos testes. Em produção a URL é `https`, então não muda nada |
| O `type` e o `data.id` da notificação vêm do corpo **ou** da query, o que estiver preenchido (a query tem prioridade no `data.id`, e o corpo, no `type`) | O `data.id` da query é o que entra no manifesto da assinatura, e o `type` pode vir em qualquer um dos dois. Um corpo ilegível não derruba a validação: sem corpo, só a query vale |
| O `motivo` do `PagamentoRecusado` cai para o próprio status (`rejected` ou `cancelled`) quando o `status_detail` vem vazio | O contrato exige o campo |
