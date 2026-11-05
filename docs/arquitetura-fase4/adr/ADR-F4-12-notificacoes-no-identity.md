# ADR-F4-12: Notificações ao cliente ficam no Identity

- **Status:** Aceito
- **Data:** 2026-11-05
- **Escopo:** Identity (consumidor) e OS (produtor dos eventos)
- **Implementação:** `fiap-soat-mecanica-identity` (`adapters/in/messaging`, `adapters/out/notification`, `infra/sqs.tf`, `infra/sns.tf`)

## Contexto

No monolito, a mudança de situação da OS enviava e-mail direto. Com a decomposição, o e-mail do cliente é dado pessoal e pertence ao Identity (LGPD). O OS não deve guardá-lo nem chamar o Identity a cada mudança de situação.

## Decisão

- O OS publica `SituacaoOrdemServicoAlterada` e `OrdemServicoCancelada` (v1) no tópico `os-eventos`. O Identity assina esse tópico na fila `mecanica-identity-notificacoes` (raw delivery, DLQ após 5 recebimentos).
- O payload traz o `clienteId`. O Identity busca o cliente, monta a notificação e chama a `NotificacaoOrdemServicoPort`.
- **Adapter de log (corte 2):** registra `notificacao_os_enviada` com o e-mail mascarado. O SMTP fica como evolução, atrás da mesma porta.
- **Cliente inexistente** não é erro do consumidor: loga `notificacao_sem_destinatario` e conclui a mensagem, porque repetir não resolve e a DLQ ficaria poluída. Erro transitório (banco fora) lança exceção e segue o redrive normal.
- **Idempotência** por `messageId`, na mesma transação do handler (esqueleto).
- **Assinatura condicional (F3-h):** o `infra/` do Identity só cria a assinatura e a policy da fila se existir o parâmetro SSM `/mecanica/os/os-eventos-topic-arn`, publicado pelo OS. O output `assinatura_os_eventos` mostra o estado no log do CD.

## Alternativas consideradas

| Alternativa | Motivo da rejeição |
|---|---|
| OS chama o Identity para buscar o e-mail e envia ele mesmo | O OS passaria a tratar dado pessoal, e cada mudança de situação viraria uma chamada síncrona |
| Evento já com o e-mail no payload | Espalha o dado pessoal pelo tópico e por todos os assinantes |
| `data "aws_ssm_parameter"` direto para o tópico | Falha com `ParameterNotFound` enquanto o OS não tiver `infra/` |

## Consequências

- O Identity depende só do contrato dos eventos, e não do código do OS. Uma cópia dos exemplos do produtor fica em `src/test/resources/contratos-consumidos/`, e o README registra a origem.
- Se o OS mudar o nome do parâmetro SSM, a assinatura nunca nasce. O `convencoes.md` fixa o nome.
- Se o OS for aplicado depois do Identity numa mesma janela, é preciso redisparar só o CD do Identity.
