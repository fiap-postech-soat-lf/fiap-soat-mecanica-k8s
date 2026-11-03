package br.com.fiap.soat.mecanica.servicobase.support;

import io.jsonwebtoken.Jwts;
import io.jsonwebtoken.security.SignatureAlgorithm;

import java.security.KeyPair;
import java.security.KeyPairGenerator;
import java.security.NoSuchAlgorithmException;
import java.time.Duration;
import java.time.Instant;
import java.util.Base64;
import java.util.Date;
import java.util.UUID;

/**
 * Tokens JWT para testes, assinados com um par RSA gerado em memoria (nenhuma chave versionada).
 * Os defaults seguem o contrato docs/contratos/jwt.md do -k8s.
 */
public final class JwtTestTokens {

    public static final String ISSUER = "fiap-soat-mecanica-identity";
    public static final String AUDIENCE = "fiap-soat-mecanica";

    private static final KeyPair PAR = gerarPar();
    private static final KeyPair OUTRO_PAR = gerarPar();

    private JwtTestTokens() {
    }

    public static String chavePublicaPem() {
        String base64 = Base64.getMimeEncoder(64, "\n".getBytes()).encodeToString(PAR.getPublic().getEncoded());
        return "-----BEGIN PUBLIC KEY-----\n" + base64 + "\n-----END PUBLIC KEY-----\n";
    }

    public static String cliente(UUID sub) {
        return token().sub(sub.toString()).principalType("CLIENTE").gerar();
    }

    public static String funcionario(UUID sub, String cargo) {
        return token().sub(sub.toString()).principalType("FUNCIONARIO").cargo(cargo).gerar();
    }

    public static Builder token() {
        return new Builder();
    }

    public static final class Builder {

        private String sub = UUID.randomUUID().toString();
        private String principalType = "CLIENTE";
        private String cargo;
        private String issuer = ISSUER;
        private String audience = AUDIENCE;
        private Instant expiraEm = Instant.now().plus(Duration.ofHours(1));
        private boolean outraChave;
        private SignatureAlgorithm algoritmo = Jwts.SIG.RS256;

        public Builder sub(String sub) {
            this.sub = sub;
            return this;
        }

        public Builder principalType(String principalType) {
            this.principalType = principalType;
            return this;
        }

        public Builder cargo(String cargo) {
            this.cargo = cargo;
            return this;
        }

        public Builder issuer(String issuer) {
            this.issuer = issuer;
            return this;
        }

        public Builder audience(String audience) {
            this.audience = audience;
            return this;
        }

        public Builder expiraEm(Instant expiraEm) {
            this.expiraEm = expiraEm;
            return this;
        }

        public Builder assinadoComOutraChave() {
            this.outraChave = true;
            return this;
        }

        public Builder algoritmo(SignatureAlgorithm algoritmo) {
            this.algoritmo = algoritmo;
            return this;
        }

        public String gerar() {
            Instant emitidoEm = expiraEm.minus(Duration.ofHours(1));
            var builder = Jwts.builder()
                    .header().keyId("mecanica-identity-v1").and()
                    .issuer(issuer)
                    .audience().add(audience).and()
                    .subject(sub)
                    .id(UUID.randomUUID().toString())
                    .issuedAt(Date.from(emitidoEm))
                    .expiration(Date.from(expiraEm));
            if (principalType != null) {
                builder.claim("principal_type", principalType);
            }
            if (cargo != null) {
                builder.claim("cargo", cargo);
            }
            return builder.signWith((outraChave ? OUTRO_PAR : PAR).getPrivate(), algoritmo).compact();
        }
    }

    private static KeyPair gerarPar() {
        try {
            KeyPairGenerator generator = KeyPairGenerator.getInstance("RSA");
            generator.initialize(2048);
            return generator.generateKeyPair();
        } catch (NoSuchAlgorithmException e) {
            throw new IllegalStateException(e);
        }
    }
}
