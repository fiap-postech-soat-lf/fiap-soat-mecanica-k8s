# ADR-F4-01: Decomposição em 4 serviços por bounded context

- **Status:** Aceito
- **Data:** 2026-11-02 (decidido no planejamento da Fase 4 e registrado na F1)
- **Escopo:** transversal (os 4 repositórios de serviço)
- **Implementação:** `fiap-soat-mecanica-identity`, `-os`, `-billing`, `-execucao`, gerados de `templates/servico-base/` por `scripts/novo-servico.sh`

## Contexto

Até a Fase 3, a oficina era um monolito Spring Boot (`fiap-soat-mecanica-api`) com um único RDS. A Fase 4 exige pelo menos 3 microsserviços, cada um com repositório, infraestrutura e banco próprios, com ao menos um banco SQL e um NoSQL, comunicação por REST e por mensageria e uma Saga com compensação.

O trabalho é individual, em 14 dias, então cada serviço a mais custa tempo de implementação, pipeline e custo de AWS Academy. O corte precisa seguir o domínio, para que a Saga e a propriedade de dados façam sentido, e não só a contagem mínima.

## Decisão

Quatro serviços, um por bounded context:

| Serviço | Responsabilidade | Por que é separado |
|---|---|---|
| **Identity** | Clientes (PF/PJ), veículos, funcionários e cargos; login de staff e por CPF (emite o JWT); notificações ao cliente | Dono dos dados pessoais e de contato (LGPD) e único emissor de tokens. Muda pouco e é muito lido |
| **OS** | Ciclo de vida e histórico da OS, catálogo de serviços e **orquestração da Saga** (ADR-F4-02) | Agregado central e fonte da verdade da situação da OS |
| **Billing** | Orçamento (aprovação, recusa, expiração), cobrança e pagamento no Mercado Pago, webhook | Integração externa e regras financeiras com ciclo e auditoria próprios |
| **Execução** | Diagnóstico, prestações, fila de execução priorizada, peças e estoque (reserva, baixa, devolução), tempos por serviço | Escrita intensa e documentos aninhados (OS → prestações → peças), o que favorece o DynamoDB; o estoque exige atualização condicional atômica |

Relações do context map:

- **OS → Execução e OS → Billing:** cliente/fornecedor (a Saga envia comandos e consome eventos).
- **Identity:** upstream de todos (identidade, veículo e JWT).
- **Mercado Pago:** entra só pelo Billing, através de uma camada anticorrupção (`MercadoPagoGatewayPort`).

O código transversal (segurança JWT, `correlationId`, envelope, outbox, consumidor idempotente, métricas e manifestos) é escrito **uma vez** no template e copiado. Uma correção no template é propagada com `scripts/comparar-esqueleto.sh`.

## Alternativas consideradas

| Alternativa | Motivo da rejeição |
|---|---|
| 3 serviços (orçamento e pagamento dentro do OS) | Cumpre o mínimo, mas mistura a integração com o Mercado Pago e as regras financeiras com o agregado da OS, e a Saga perde um participante real |
| 5 ou mais (Estoque separado do Execução, Notificação separada do Identity) | A reserva de peças e a fila de execução mudam juntas, e a notificação depende dos dados de contato do Identity. Mais repositórios, pipelines e pods para uma pessoa, sem ganho de autonomia |
| Monolito modular com um banco por módulo | Não atende o requisito de repositório, deploy e banco independentes por serviço |

## Consequências

**Positivas**
- Cada contexto tem dono claro dos dados (ADR-F4-05) e um único motivo para mudar.
- A Saga tem 3 participantes reais (OS, Execução e Billing), com compensação de verdade na reserva de peças e no orçamento.
- O template reduz o custo de cada serviço: na F1, os 4 foram gerados com o mesmo esqueleto, cada um com CI, Sonar e ruleset próprios.

**Negativas / riscos**
- Consultas que antes eram um `JOIN` passam a exigir REST síncrono (validação do veículo no Identity e do serviço no catálogo do OS) ou snapshot de dados na mensagem. Isso cobra timeout, retry e circuit breaker (ADR-F4-09).
- 4 pods, 3 RDS e 4 pipelines aumentam o custo e o tempo de subida do ambiente no Academy.
- Correções no código comum precisam ser propagadas para os 4 repositórios.
