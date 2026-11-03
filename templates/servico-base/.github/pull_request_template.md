## Alteração

Descreva a mudança e o efeito dela nas rotas, nas mensagens, no banco ou na infraestrutura do serviço.

## Validação

- [ ] `./mvnw verify` (testes e cobertura ≥ 80%)
- [ ] `terraform -chdir=infra fmt -check -recursive && terraform -chdir=infra validate` (se mexeu no `infra/`)
- [ ] Testes novos ou atualizados quando a regra mudou

## Segurança e contratos

- [ ] Não inclui segredo, chave, token real ou dado pessoal
- [ ] Rota nova protegida por JWT (ou listada como pública em `rotas.md`, com justificativa)
- [ ] Mensagens publicadas pelo `OutboxPort` e compatíveis com os contratos em `docs/contratos/`
- [ ] Mudança de contrato segue a regra de congelamento (seção 7.3 do plano da F1)
