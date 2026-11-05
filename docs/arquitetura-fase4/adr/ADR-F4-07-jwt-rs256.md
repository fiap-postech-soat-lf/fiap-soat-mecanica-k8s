# ADR-F4-07: JWT RS256 emitido pelo Identity

- **Status:** Aceito
- **Data:** 2026-11-04 (chaves, F2); 2026-11-05 (emissão e logins, F3)
- **Escopo:** Identity (emissão), `-auth` (authorizer) e os 4 serviços (validação)
- **Implementação:** `fiap-soat-mecanica-identity/infra/jwt.tf` e `adapters/out/security/JwtTokenIssuerAdapter`; `fiap-soat-mecanica-auth/infra/lambda.tf`; `docs/contratos/jwt.md`

## Contexto

O token é emitido pelo Identity e validado em dois lugares: no Lambda Authorizer (ADR-F4-06) e em cada serviço (defesa em profundidade). Com HS256, todos que validam teriam o segredo de assinatura, ou seja, qualquer serviço poderia emitir tokens. Com RS256, só o Identity tem a chave privada, e os outros recebem a chave pública.

O ambiente é destruído e recriado a cada janela. O par de chaves precisa nascer com o ambiente, sem passo manual.

## Decisão

### Token e logins (F3)

- **Formato:** RS256, `kid=mecanica-identity-v1`, claims e TTL de 1 h em `docs/contratos/jwt.md`.
- **Dois logins públicos** no Identity, com o mesmo corpo de resposta `{accessToken, tokenType, expiresIn}`: `POST /auth/login` (e-mail e senha, funcionário) e `POST /auth/cpf` (cliente PF).
- **Emissão atrás de uma porta:** `TokenIssuerPort` em `application/` e o adapter em `adapters/out/security/`. Isso corrige a dependência de `application` para `adapters` que o monolito tinha. O `JwtService` HS256 não foi portado.
- **Erros sem enumeração:** no login de staff, e-mail inexistente, senha errada e usuário inativo dão o mesmo 401. No login por CPF, formato inválido é 400, e cliente inexistente, inativo ou PJ é 401. O monolito devolvia 404 para e-mail inexistente.
- **Chave ausente:** o serviço sobe e os logins respondem 503 (`EMISSOR_INDISPONIVEL`).
- **Par trocado:** com as duas chaves presentes que não formam par, a aplicação não sobe (`par_jwt_inconsistente`). O rollout do CD fica vermelho, em vez de ir ao ar rejeitando todo token.
- **Quem chama, sem banco:** a porta `UsuarioAutenticadoPort` expõe `sub`, tipo e cargo a partir do token. O `sub` é o `usuario_id` do cliente cadastrado.
- **Entre serviços:** o chamador repassa o JWT de quem o chamou (F3-a). Sem token de serviço.
- **Rotação:** par novo a cada janela. JWKS fica como evolução.

### Chaves (F2)

- **Geração:** `tls_private_key` (RSA 2048) no Terraform do Identity. Cada janela gera um par novo.
- **Chave privada:** no Secrets Manager `mecanica-identity-jwt` (`{privateKeyPem, publicKeyPem}`, privada em PKCS#8, `recovery_window_in_days = 0`). O ARN fica no SSM `/mecanica/identity/jwt-secret-arn`. Na F3, o Identity a recebe como `JWT_PRIVATE_KEY` no Secret do Kubernetes (`app_secrets`).
- **Chave pública:** no SSM `/mecanica/identity/jwt-public-key` (String), porque não é segredo.
  - O `infra/` do `-auth` lê o parâmetro e o passa à Lambda como variável de ambiente `JWT_PUBLIC_KEY`, com o `\n` escapado.
  - Os serviços a recebem em `JWT_PUBLIC_KEY` pelo `app_config` do Identity.
- **Formato aceito:** PEM ou PEM com `\n` escapado, porque o `--from-env-file` do `kubectl` e as variáveis de ambiente da Lambda não aceitam valor multilinha.

## Alternativas consideradas (token e emissão)

| Alternativa | Motivo da rejeição |
|---|---|
| HS256 com segredo compartilhado | Todo validador teria o segredo e poderia emitir token. É o que o monolito fazia |
| Token de serviço para as chamadas entre serviços | Exigiria um novo tipo de principal no contrato, no authorizer e nos 4 validadores. Repassar o JWT de quem chamou reaproveita o que já existe (F3-a) |
| Subir sem validar o par de chaves | Um par trocado só apareceria como 401/403 em tudo, depois do deploy |

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

## Consequências (emissão)

- **Login de staff com BCrypt** custa ~0,5 s com 250m de CPU. É aceito, porque são poucos logins.
- **Senha de teste no seed:** o seed do Identity (`Senha@123`, só o hash BCrypt no repositório) é aceito por ser ambiente acadêmico.
- **Um par trocado derruba o deploy**, o que é intencional: a falha aparece no CD, e não em produção.
