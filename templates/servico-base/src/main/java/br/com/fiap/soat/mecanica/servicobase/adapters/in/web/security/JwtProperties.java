package br.com.fiap.soat.mecanica.servicobase.adapters.in.web.security;

import org.springframework.boot.context.properties.ConfigurationProperties;

/**
 * Configuracao do JWT RS256 emitido pelo Identity (contrato em docs/contratos/jwt.md do -k8s).
 *
 * @param publicKey chave publica em PEM (X.509 SubjectPublicKeyInfo) ou "file:&lt;caminho&gt;" para ler de arquivo
 * @param issuer    valor exigido no claim iss
 * @param audience  valor que o claim aud precisa conter
 */
@ConfigurationProperties("app.security.jwt")
public record JwtProperties(String publicKey, String issuer, String audience) {
}
