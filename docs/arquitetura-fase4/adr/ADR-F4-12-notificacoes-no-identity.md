# ADR-F4-12: Notificações ao cliente ficam no Identity

- **Status:** Aceito
- **Data:** 2026-11-05. Revisada no mesmo dia: a assinatura passou para o OS (F4-a)
- **Escopo:** Identity (consumidor) e OS (produtor dos eventos)
- **Implementação:** `fiap-soat-mecanica-identity` (`adapters/in/messaging`, `adapters/out/notification`, `infra/sqs.tf`); assinatura em `fiap-soat-mecanica-os` (`infra/sns.tf`)

## Contexto

No monolito, a mudança de situação da OS enviava e-mail direto. Com a decomposição, o e-mail do cliente é dado pessoal e pertence ao Identity (LGPD). O OS não deve guardá-lo nem chamar o Identity a cada mudança de situação.

## Decisão

- O OS publica `SituacaoOrdemServicoAlterada` e `OrdemServicoCancelada` (v1) no tópico `os-eventos`. O Identity assina esse tópico na fila `mecanica-identity-notificacoes` (raw delivery, DLQ após 5 recebimentos).
- O payload traz o `clienteId`. O Identity busca o cliente, monta a notificação e chama a `NotificacaoOrdemServicoPort`.
- **Adapter de log (corte 2):** registra `notificacao_os_enviada` com o e-mail mascarado. O SMTP fica como evolução, atrás da mesma porta.
- **Cliente inexistente** não é erro do consumidor: loga `notificacao_sem_destinatario` e conclui a mensagem, porque repetir não resolve e a DLQ ficaria poluída. Erro transitório (banco fora) lança exceção e segue o redrive normal.
- **Idempotência** por `messageId`, na mesma transação do handler (esqueleto).
- **Assinatura no `infra/` do OS (F4-a, que substitui a F3-h):** o Identity cria a fila e **sempre** a queue policy, com o ARN do tópico montado a partir do nome (`arn:aws:sns:<região>:<conta>:mecanica-os-eventos`), e publica a fila em `/mecanica/identity/notificacoes-queue-arn`. O `infra/` do OS cria o tópico e a assinatura (`raw_message_delivery = true`) lendo esse parâmetro. O Identity não depende mais de nada do OS, e a ordem de provisionamento passa a ser `identity` → ... → `os` (ADR-F4-03).

## Alternativas consideradas

| Alternativa | Motivo da rejeição |
|---|---|
| OS chama o Identity para buscar o e-mail e envia ele mesmo | O OS passaria a tratar dado pessoal, e cada mudança de situação viraria uma chamada síncrona |
| Evento já com o e-mail no payload | Espalha o dado pessoal pelo tópico e por todos os assinantes |
| Assinatura condicional no Identity (F3-h), lendo o tópico do OS por SSM | Exige o OS antes do Identity, e o OS precisa da chave pública do Identity: numa subida do zero, o OS subiria sem chave |
| `data "aws_ssm_parameter"` direto para o tópico no Identity | Falha com `ParameterNotFound` enquanto o OS não tiver `infra/` |

## Consequências

- O Identity depende só do contrato dos eventos, e não do código do OS. Uma cópia dos exemplos do produtor fica em `src/test/resources/contratos-consumidos/`, e o README registra a origem.
- Se o Identity mudar o nome do parâmetro `notificacoes-queue-arn`, o `plan` do OS falha com `ParameterNotFound`, o que é o comportamento desejado. O `convencoes.md` fixa o nome.
- A assinatura é uma exceção à regra "o consumidor é dono da assinatura" (ADR-F4-03). Ela existe só para desfazer o ciclo da chave pública.
- A OS publica só `OrdemServicoCancelada` no cancelamento (sem `SituacaoOrdemServicoAlterada` para `CANCELADA`), para o cliente ser notificado uma vez (ADR-F4-02).
