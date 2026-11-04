# ADR-F4-07: JWT RS256 emitido pelo Identity

- **Status:** Proposto (seção de chaves aceita na F2; emissão e logins fecham na F3)
- **Data:** 2026-11-04
- **Escopo:** Identity (emissão), `-auth` (authorizer) e os 4 serviços (validação)
- **Implementação:** `fiap-soat-mecanica-identity/infra/jwt.tf`; `fiap-soat-mecanica-auth/infra/lambda.tf`; `docs/contratos/jwt.md`

## Contexto

O token é emitido pelo Identity e validado em dois lugares: no Lambda Authorizer (ADR-F4-06) e em cada serviço (defesa em profundidade). Com HS256, todos que validam teriam o segredo de assinatura, ou seja, qualquer serviço poderia emitir tokens. Com RS256, só o Identity tem a chave privada, e os outros recebem a chave pública.

O ambiente é destruído e recriado a cada janela. O par de chaves precisa nascer com o ambiente, sem passo manual.

## Decisão

> **Pendente (F3):** formato do token, claims, logins de funcionário e por CPF, `kid` e rotação. O formato já está congelado em `docs/contratos/jwt.md`.

### Chaves (F2)

- **Geração:** `tls_private_key` (RSA 2048) no Terraform do Identity. Cada janela gera um par novo.
- **Chave privada:** no Secrets Manager `mecanica-identity-jwt` (`{privateKeyPem, publicKeyPem}`, privada em PKCS#8, `recovery_window_in_days = 0`). O ARN fica no SSM `/mecanica/identity/jwt-secret-arn`. Na F3, o Identity a recebe como `JWT_PRIVATE_KEY` no Secret do Kubernetes (`app_secrets`).
- **Chave pública:** no SSM `/mecanica/identity/jwt-public-key` (String), porque não é segredo.
  - O `infra/` do `-auth` lê o parâmetro e o passa à Lambda como variável de ambiente `JWT_PUBLIC_KEY`, com o `\n` escapado.
  - Os serviços a recebem em `JWT_PUBLIC_KEY` pelo `app_config` do Identity.
- **Formato aceito:** PEM ou PEM com `\n` escapado, porque o `--from-env-file` do `kubectl` e as variáveis de ambiente da Lambda não aceitam valor multilinha.

## Alternativas consideradas (chaves)

| Alternativa | Motivo da rejeição |
|---|---|
| Lambda lê a chave pública do Secrets Manager na inicialização | A Lambda passaria a ler o secret que contém a chave privada. Como ela roda com a `LabRole`, que é ampla e não pode ser trocada por uma role restrita, não há como limitá-la à chave pública. Também acrescenta uma chamada de rede no cold start |
| Par gerado por script fora do Terraform e gravado à mão | Passo manual em cada janela, e a chave ficaria no notebook |
| Par fixo versionado ou criado uma vez e preservado entre janelas | Exigiria um recurso fora do ciclo destroy/apply. Trocar a chave a cada janela é aceitável porque o TTL do token é 1 h |
| JWKS publicado pelo Identity | Os validadores dependeriam do Identity no ar e de HTTP de saída. É o caminho natural para rotação sem redeploy, mas fica fora do escopo |

## Consequências (chaves)

- **Chave privada no state:** o `tls_private_key` fica no state do Terraform do Identity. Quem lê o bucket `mecanica-tfstate-<conta>` lê a chave. Isso é aceito porque o bucket é privado, criptografado e versionado, com bloqueio de acesso público, e a chave vale só por uma janela.
- **Tokens não sobrevivem à janela:** um destroy/apply invalida todos os tokens emitidos antes. Os testes manuais e o Postman precisam de login novo a cada janela.
- **Ordem de deploy:** trocar a chave exige reaplicar o `-auth` depois do Identity, e os pods dos serviços precisam de rollout para ler o `app_config` novo. O `subir-ambiente.sh` segue essa ordem (Identity → `-auth`).
- **A Lambda não vê a chave privada** e não chama nenhum serviço da AWS ao validar.
