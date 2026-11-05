# JWT da Fase 4

O **Identity** emite o token (login de funcionário e login por CPF do cliente). O **Lambda Authorizer** (`-auth`) e **cada serviço** validam o token, cada um por conta própria (defesa em profundidade).

## Formato

**Header**

| Campo | Valor |
|---|---|
| `alg` | `RS256` (único aceito: RS384/RS512 são rejeitados mesmo com a mesma chave) |
| `typ` | `JWT` |
| `kid` | `mecanica-identity-v1` |

**Claims**

| Claim | Valor | Obrigatório |
|---|---|---|
| `iss` | `fiap-soat-mecanica-identity` | sim |
| `aud` | `fiap-soat-mecanica` | sim |
| `sub` | UUID do cliente ou do funcionário | sim |
| `principal_type` | `CLIENTE` ou `FUNCIONARIO` | sim |
| `cargo` | `ATENDENTE`, `MECANICO` ou `ALMOXARIFE` | só para `FUNCIONARIO` (ignorado para `CLIENTE`) |
| `iat` | emissão (epoch em segundos) | sim |
| `exp` | `iat + 3600` | sim |
| `jti` | UUID do token | sim |

Exemplo de payload:

```json
{
  "iss": "fiap-soat-mecanica-identity",
  "aud": "fiap-soat-mecanica",
  "sub": "99999999-7777-4888-8999-000000000000",
  "principal_type": "FUNCIONARIO",
  "cargo": "MECANICO",
  "iat": 1793670948,
  "exp": 1793674548,
  "jti": "4fbd9158-5d62-4b2a-82c0-20e63d762419"
}
```

## Emissão

O Identity emite o token em dois logins públicos, que devolvem o mesmo corpo (200, com `Cache-Control: no-store`):

```json
{ "accessToken": "<jwt>", "tokenType": "Bearer", "expiresIn": 3600 }
```

| Login | Corpo da requisição | Token emitido |
|---|---|---|
| `POST /auth/login` | `{"email", "senha"}` | `principal_type=FUNCIONARIO`, com o `cargo` do usuário |
| `POST /auth/cpf` | `{"cpf"}` (com ou sem máscara) | `principal_type=CLIENTE`, sem `cargo`. Só cliente PF ativo; PJ não tem CPF |

**Erros** (sempre no `ErrorResponse` do serviço, sem enumeração de usuários):

| Situação | Status | Código |
|---|---|---|
| Staff: e-mail inexistente, senha errada ou usuário inativo (mesma mensagem nos três casos) | 401 | `CREDENCIAIS_INVALIDAS` |
| CPF com formato ou dígito inválido | 400 | `CPF_INVALIDO` |
| CPF válido, mas cliente inexistente, inativo ou PJ | 401 | `ACESSO_NEGADO` |
| Identity sem chave privada | 503 | `EMISSOR_INDISPONIVEL` |

**Emissor:** `JwtTokenIssuerAdapter` assina com `JWT_PRIVATE_KEY` (PKCS#8; PEM, PEM com `\n` escapado ou `file:<caminho>`), `kid=mecanica-identity-v1`, `exp = iat + 3600` e `jti` novo a cada emissão.

- **Sem `JWT_PRIVATE_KEY`:** o serviço sobe, os logins respondem 503 e o log registra `chave_privada_ausente`.
- **Chaves que não formam par:** com as duas chaves presentes, o Identity assina um token de amostra e o valida na inicialização. Se falhar, lança `IllegalStateException("par_jwt_inconsistente")` e **não sobe**. Assim, um par trocado derruba o rollout do CD em vez de ir ao ar rejeitando todo token.
- Os logs `login_aceito` e `login_negado` trazem `principalType` e `motivo`, nunca e-mail, CPF, senha ou token.

## Validação nos serviços

Implementada no `JwtTokenValidator` do esqueleto:

- assinatura RS256 com a chave pública do Identity, e `alg` diferente de `RS256` é rejeitado;
- `iss` e `aud` exatos, e `exp` com tolerância de 30 s de relógio;
- `sub` precisa ser UUID, e `principal_type` precisa ser `CLIENTE` ou `FUNCIONARIO`;
- `FUNCIONARIO` sem `cargo`, ou com cargo fora da lista, é rejeitado.

O token aceito vira as authorities `ROLE_<principal_type>` e, para funcionário, `ROLE_<cargo>`. Exemplo: `@PreAuthorize("hasRole('MECANICO')")`. Token ausente ou inválido responde **401** em JSON; token válido sem permissão responde **403**.

## Chaves

| Onde | O quê |
|---|---|
| Terraform do Identity (`infra/jwt.tf`) | Gera o par: `tls_private_key` RSA 2048, a cada janela de integração |
| Secrets Manager `mecanica-identity-jwt` | `{ "privateKeyPem": ..., "publicKeyPem": ... }` (privada em PKCS#8); o ARN fica no SSM `/mecanica/identity/jwt-secret-arn` |
| SSM `/mecanica/identity/jwt-public-key` | Chave pública (String), lida pelo `infra/` do `-auth` e passada à Lambda como `JWT_PUBLIC_KEY` |
| Serviços (EKS) | Chave pública em `JWT_PUBLIC_KEY` (`app.security.jwt.public-key`), aceita como PEM ou PEM com `\n` escapado; vem do `app_config` do Identity |
| Ambiente local | Par de dev de `local/jwt/gerar-chaves-dev.sh` (ignorado pelo git); tokens com `local/jwt/gerar-token-dev.sh <CLIENTE\|ATENDENTE\|MECANICO\|ALMOXARIFE> [sub]` (`CHAVE_PRIVADA=<arquivo>` assina com outra chave) |

- Cada janela gera um par novo, então os tokens de janelas anteriores deixam de valer.
- A chave privada fica também no state do Terraform do Identity (bucket privado, criptografado e versionado). Isso é aceito e registrado na ADR-F4-07.
- A Lambda não lê o Secrets Manager nem tem acesso à chave privada. Trocar a chave exige reaplicar o `-auth` depois do Identity (o `subir-ambiente.sh` já segue essa ordem).

Sem chave configurada, o serviço (e a Lambda) sobe e rejeita todo token (`chave_publica_ausente`).

## Authorizer na borda

O Lambda Authorizer (`mecanica-authorizer`, do `-auth`) aplica as mesmas regras da validação nos serviços, sem Spring. Ele é um authorizer `REQUEST` do HTTP API, com payload 2.0 e resposta simples (`isAuthorized`).

| Situação | Resposta do API Gateway |
|---|---|
| Sem header `Authorization` | **401** `Unauthorized`. O API Gateway nem chama a Lambda (identity source ausente) |
| Token inválido (assinatura, `alg`, `iss`, `aud`, `exp`, `sub`, `principal_type`, `cargo`) ou sem `Bearer` | **403** `Forbidden` (`isAuthorized=false`, log `autorizacao_negada` com o `motivo`, nunca o token) |
| Token válido | Encaminha ao NLB pela integração `protegida` |

- A decisão fica em **cache por 300 s**, com chave no header `Authorization`. Um token que expira nesse intervalo ainda passa pela borda, mas o serviço valida o `exp` de novo.
- Rotas públicas e fallback protegido em [rotas.md](rotas.md#como-o-api-gateway-encaminha).

## Contexto do Authorizer

O Lambda Authorizer devolve o contexto `{sub, principalType, cargo}` (`cargo = ""` para `CLIENTE`, porque o contexto não aceita `null`). A integração `protegida` o repassa ao backend nos headers `x-user-sub`, `x-user-principal-type` e `x-user-cargo`, mais `x-correlation-id = $context.requestId`. Nas rotas públicas, os `x-user-*` enviados pelo cliente são removidos.

Os serviços **não** autenticam por esses headers, só pelo token. O `x-correlation-id` vira o `correlationId` dos logs e das mensagens.
