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
| Secrets Manager `mecanica-identity-jwt` | `{ "privateKeyPem": ..., "publicKeyPem": ... }`; o ARN fica no SSM `/mecanica/identity/jwt-secret-arn` (criado na F2) |
| Serviços (EKS) | Chave pública em `JWT_PUBLIC_KEY` (`app.security.jwt.public-key`), aceita como PEM ou PEM com `\n` escapado |
| Ambiente local | Par de dev de `local/jwt/gerar-chaves-dev.sh` (ignorado pelo git); tokens com `local/jwt/gerar-token-dev.sh <CLIENTE\|ATENDENTE\|MECANICO\|ALMOXARIFE> [sub]` |

Sem chave configurada, o serviço sobe e rejeita todo token (`chave_publica_ausente`).

## Contexto do Authorizer

O Lambda Authorizer repassa ao backend os headers `x-user-sub`, `x-user-principal-type` e `x-user-cargo`, mais `x-correlation-id = $context.requestId`. Os serviços **não** autenticam por esses headers, só pelo token. O `x-correlation-id` vira o `correlationId` dos logs e das mensagens.
