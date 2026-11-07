# ADR-F4-02: Saga orquestrada no OS, com pivô em `IniciarExecucao`

- **Status:** Aceito
- **Data:** 2026-11-02 (decidido no planejamento da Fase 4 e registrado na F1). Revisada em 2026-11-05 com a implementação da F4 (F4-e a F4-i) e em 2026-11-07 com a do Billing na F6 (F6-d, F6-f e F6-g)
- **Escopo:** transversal; o orquestrador fica em `fiap-soat-mecanica-os`
- **Implementação:** contratos dos comandos e eventos em `docs/contratos/` de cada produtor (F1); orquestrador na F4

## Contexto

O atendimento de uma OS atravessa três serviços. A OS abre, o Execução diagnostica e reserva peças, o Billing gera o orçamento e o cliente aprova ou recusa. Depois o Execução executa, e o Billing cobra e confirma o pagamento. Sem transação distribuída, cada falha no meio do caminho precisa de um tratamento explícito. Exemplos: peça sem estoque, orçamento que falha, recusa ou expiração e pagamento recusado.

## Decisão

**Orquestração** no OS. Ele guarda o estado da Saga (`saga_instancia` com `passoAtual` e status `INICIADA`, `COMPENSANDO`, `COMPENSADA`, `CONCLUIDA` ou `FALHOU`, mais `saga_passo` como log). Também envia os comandos para a fila do participante e reage aos eventos de resposta.

| # | Passo | Comando → resposta | Falha | Tratamento |
|---|---|---|---|---|
| 1 | Abrir OS | validação REST do veículo no Identity | veículo inválido ou Identity fora | rejeita de forma síncrona; a Saga não começa |
| 2 | Abrir diagnóstico | `AbrirDiagnostico` → `DiagnosticoAberto` | timeout | reenvia (idempotente); após 3 tentativas, OS `CANCELADA` e saga `FALHOU` |
| 3 | Diagnosticar (REST no Execução) | → `DiagnosticoConcluido` | — | — |
| 4 | Reservar peças | `ReservarPecas` → `PecasReservadas` | `ReservaPecasRecusada` | OS volta a `EM_DIAGNOSTICO`; nada a desfazer, porque a reserva é atômica |
| 5 | Gerar orçamento | `GerarOrcamento` → `OrcamentoGerado` | `OrcamentoFalhou` ou timeout | `LiberarReservaPecas`; OS volta a `EM_DIAGNOSTICO` |
| 6 | Aprovação do cliente | → `OrcamentoAprovado` | recusa, expiração ou desistência | OS `CANCELADA` **na hora da decisão**; `LiberarReservaPecas` (+ `CancelarOrcamento` na desistência); saga `COMPENSANDO` e, com a `ReservaPecasLiberada`, `COMPENSADA` |
| 7 | **Pivô** | `IniciarExecucao` → `ExecucaoIniciada` (reserva vira baixa) | timeout | a partir daqui, **só recuperação para frente**: retry com backoff e, esgotado, DLQ + alerta |
| 8 | Executar | → `ExecucaoFinalizada` | — | — |
| 9 | Cobrar | `SolicitarPagamento` → `CobrancaCriada` | erro no Mercado Pago | retry com backoff |
| 10 | Pagamento | webhook → `PagamentoConfirmado` | `PagamentoRecusado` | sem compensação (o serviço já foi feito); a OS segue `AGUARDANDO_PAGAMENTO` e uma nova cobrança é gerada |

Mecanismos:

- **Situação da OS × estado da Saga (F4-e):** a situação da OS é a verdade do negócio e muda **na hora** da decisão (recusa, expiração ou desistência → `CANCELADA`). A Saga fica `COMPENSANDO` até chegar a `ReservaPecasLiberada` e então vira `COMPENSADA`; sem reserva a desfazer, vai direto a `COMPENSADA`. No cancelamento o OS publica **só** `OrdemServicoCancelada`, sem uma `SituacaoOrdemServicoAlterada` com `para = CANCELADA`, porque os dois eventos fariam o Identity notificar o cliente duas vezes (ADR-F4-12).
- **Respostas fora de hora (F4-f):** uma resposta que não corresponde ao passo atual é descartada, com o log `resposta_fora_do_passo` e uma linha `DESCARTADA` em `saga_passo`. **Exceção:** uma resposta tardia que criou um recurso numa Saga já cancelada dispara a compensação (`PecasReservadas` → `LiberarReservaPecas`; `OrcamentoGerado` → `CancelarOrcamento`). Sem isso, uma reserva ou um orçamento criados depois do cancelamento ficariam presos.
- **Diagnóstico sem peças e nova reserva (F4-g):** se nenhum item do `DiagnosticoConcluido` tem peças, a Saga pula a reserva e vai direto ao `GerarOrcamento`. Se ainda há uma liberação pendente (revisão ou falha do orçamento), o OS guarda o novo diagnóstico e **só envia o `ReservarPecas` quando chegar a `ReservaPecasLiberada`**. As filas são padrão, sem ordem garantida: a nova reserva poderia ser processada antes da liberação da anterior.
- **Reenvio por timeout (F4-h):** o reenvio cria um **envelope novo** (`messageId` novo, mesmo payload, `causationId` = o comando original). Requisito para os participantes: idempotência pela chave de negócio (`osId` + tipo de comando) e **reemissão da resposta** quando recebem de novo um comando que já atenderam. Reenviar com o mesmo `messageId` não resolveria o caso da resposta perdida, porque o participante já deduplicou aquele `messageId`.
- **Timeouts (F4-i):** um `SagaTimeoutScheduler` roda a cada 30 s sobre `saga_instancia.prazo_em`, com `FOR UPDATE SKIP LOCKED` (o OS roda com 2 réplicas). Prazos na tabela abaixo. **O TTL da aprovação é do Billing** (`expiraEm` do `OrcamentoGerado`); o OS só usa um prazo de segurança de `expiraEm` + 1 min. Nas esperas humanas (diagnóstico, execução e pagamento) não há timeout.
- **TTL da aprovação no Billing (F6-f):** o `ExpiracaoOrcamentoScheduler` do Billing (30 s, `FOR UPDATE SKIP LOCKED`) expira o orçamento `GERADO` vencido e emite `OrcamentoExpirado`; `app.orcamento.ttl` é `PT24H` no EKS. Aprovar ou recusar depois de `expiraEm` dá 422 mesmo antes de o scheduler rodar, e a corrida aprovar × expirar termina em 409 (`@Version`). Um `GerarOrcamento` de nova rodada cancela o `GERADO` anterior (`SUBSTITUIDO`), porque o `CancelarOrcamento` da revisão pode chegar depois (filas padrão), e há no máximo um orçamento vivo por OS (índice único parcial). O OS descarta o `OrcamentoAprovado` de uma Saga já cancelada e manda o cancelamento, então "aprova enquanto o atendente cancela" termina com o orçamento `CANCELADO`.
- **Cobrança só para a frente (F6-g):** o `SolicitarPagamento` cria o `Pagamento` e a preferência no Mercado Pago **dentro da transação do handler**. Se o Mercado Pago falhar, a transação é desfeita, a mensagem volta à fila e o OS reenvia: o contrato não tem um "cobrança falhou", e depois do pivô não há compensação. Há um pagamento vigente por OS; o `PagamentoRecusado` não compensa nada, e a nova cobrança (`SUBSTITUIDO` + novo `PENDENTE`) é uma ação do atendente. Só o vigente gera `PagamentoConfirmado`, porque o OS não confere o `pagamentoId`.
- **Retries:** até 3 tentativas por comando. Depois do pivô, com backoff (2, 4 e 8 min).
- **Concorrência:** `@Version` em `saga_instancia`. Dois handlers na mesma Saga: um pega `OptimisticLockException`, a transação (e a linha de idempotência) é desfeita, e a mensagem volta depois do visibility timeout. Nas rotas REST o mesmo conflito vira 409 `CONFLITO_CONCORRENTE`.
- **Notificação:** cada mudança de situação publica `SituacaoOrdemServicoAlterada` em `mecanica-os-eventos`, que o Identity usa para notificar o cliente.

**Prazos e o que acontece quando vencem**

| Passo | Prazo | Ao vencer, enquanto houver tentativas (3) | Quando as tentativas acabam |
|---|---|---|---|
| `ABRIR_DIAGNOSTICO` | 2 min | reenvia `AbrirDiagnostico` | OS `CANCELADA` ("Execução não respondeu"), Saga `FALHOU` |
| `RESERVAR_PECAS` | 2 min | reenvia `ReservarPecas` | `LiberarReservaPecas` por garantia; OS continua `EM_DIAGNOSTICO` com motivo |
| `GERAR_ORCAMENTO` | 2 min | reenvia `GerarOrcamento` | mesmo efeito de `OrcamentoFalhou` |
| `AGUARDAR_APROVACAO` | `expiraEm` + 1 min | — | mesmo efeito de `OrcamentoExpirado`, mais `CancelarOrcamento` (rede de segurança) |
| liberação pendente | 2 min | reenvia `LiberarReservaPecas` | Saga `FALHOU` (alerta); a OS não muda |
| `INICIAR_EXECUCAO` e `SOLICITAR_PAGAMENTO` (depois do pivô) | 2 min, com backoff | reenvia | Saga `FALHOU` (alerta); a OS fica onde está, com ação manual |
| `AGUARDAR_DIAGNOSTICO`, `AGUARDAR_EXECUCAO`, `AGUARDAR_PAGAMENTO` | sem prazo | — | — |

**Estados da OS e da Saga no cancelamento**

```
RECEBIDA ─► EM_DIAGNOSTICO ◄──────────────┐ (reserva recusada, orçamento falhou, revisão)
                │                         │
                ▼                         │
        AGUARDANDO_APROVACAO ─────────────┘
          │ recusa / expiração / desistência      │ aprovado (pivô)
          ▼                                       ▼
   OS CANCELADA (na hora)                    EM_EXECUCAO ─► FINALIZADA ─► AGUARDANDO_PAGAMENTO ─► ENTREGUE
   Saga COMPENSANDO ─(ReservaPecasLiberada)─► COMPENSADA
```

## Alternativas consideradas

| Alternativa | Motivo da rejeição |
|---|---|
| Coreografia (cada serviço reage aos eventos dos outros) | O fluxo fica espalhado em 3 serviços, sem um lugar que responda "em que passo esta OS está?". As compensações dependem de cada participante conhecer o fluxo inteiro, e os ciclos de eventos são difíceis de testar |
| Orquestrador separado (serviço "Saga") | Mais um repositório e um pod, e a situação da OS ficaria fora do agregado que é dono dela |
| Motor de workflow gerenciado (Step Functions) ou Temporal | Outro modelo de programação e outra dependência de infraestrutura no Academy. A Saga tem 10 passos lineares, que cabem numa máquina de estados persistida no próprio OS |

## Consequências

**Positivas**
- O estado da Saga é consultável num lugar só (`saga_instancia`), e as compensações ficam explícitas e testáveis com BDD no OS (F4).
- O pivô deixa claro o ponto sem volta. Antes dele, tudo é desfeito; depois, só há retry. Isso evita "descompensar" um serviço que já foi executado.
- Os participantes são simples: recebem um comando, respondem com um evento e não conhecem o fluxo.

**Negativas / riscos**
- O OS concentra lógica e é crítico. Ele roda com mínimo de 2 réplicas, e o `SKIP LOCKED` da outbox e do scheduler de timeouts (ADR-F4-04) protege o processamento com várias réplicas.
- Os timeouts e retries precisam ser idempotentes de ponta a ponta. Os consumidores deduplicam por `messageId` (ADR-F4-04), e os participantes (Execução e Billing) também pela chave de negócio, reemitindo a resposta (F4-h). Se a F5 ou a F6 deduplicarem só por `messageId`, um reenvio por timeout nunca será respondido.
- A situação da OS e o estado da Saga divergem por instantes no cancelamento (`CANCELADA` com a Saga `COMPENSANDO`). Quem consulta precisa ler os dois campos (`GET /ordem-servicos/{id}` devolve `sagaStatus`).
- Uma mensagem esgotada na DLQ deixa a Saga parada até alguém agir. Por isso a métrica `dlq.depth` e o alerta no Datadog.
