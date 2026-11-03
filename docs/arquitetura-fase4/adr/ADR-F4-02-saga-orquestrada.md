# ADR-F4-02: Saga orquestrada no OS, com pivô em `IniciarExecucao`

- **Status:** Aceito
- **Data:** 2026-11-02 (decidido no planejamento da Fase 4 e registrado na F1)
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
| 6 | Aprovação do cliente | → `OrcamentoAprovado` | recusa, expiração ou desistência | `LiberarReservaPecas` (+ `CancelarOrcamento` na desistência); OS `CANCELADA`, saga `COMPENSADA` |
| 7 | **Pivô** | `IniciarExecucao` → `ExecucaoIniciada` (reserva vira baixa) | timeout | a partir daqui, **só recuperação para frente**: retry com backoff e, esgotado, DLQ + alerta |
| 8 | Executar | → `ExecucaoFinalizada` | — | — |
| 9 | Cobrar | `SolicitarPagamento` → `CobrancaCriada` | erro no Mercado Pago | retry com backoff |
| 10 | Pagamento | webhook → `PagamentoConfirmado` | `PagamentoRecusado` | sem compensação (o serviço já foi feito); a OS segue `AGUARDANDO_PAGAMENTO` e uma nova cobrança é gerada |

Mecanismos:

- **Timeouts:** um `SagaTimeoutScheduler` roda a cada 30 s. O prazo é de 2 min por comando. A aprovação do orçamento tem TTL configurável: 24 h, ou 2 min no perfil de demo.
- **Retries:** até 3 tentativas, com backoff exponencial.
- **Respostas fora de ordem:** o OS descarta as que não correspondem ao passo atual.
- **Notificação:** cada mudança de situação publica `SituacaoOrdemServicoAlterada` em `mecanica-os-eventos`, que o Identity usa para notificar o cliente.

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
- O OS concentra lógica e é crítico. Ele roda com mínimo de 2 réplicas, e o `SKIP LOCKED` da outbox (ADR-F4-04) protege a publicação com várias réplicas.
- Os timeouts e retries precisam ser idempotentes de ponta a ponta. Os consumidores deduplicam por `messageId` (ADR-F4-04).
- Uma mensagem esgotada na DLQ deixa a Saga parada até alguém agir. Por isso a métrica `dlq.depth` e o alerta no Datadog.
