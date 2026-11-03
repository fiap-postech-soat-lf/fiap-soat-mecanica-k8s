package br.com.fiap.soat.mecanica.servicobase.adapters.in.web.security;

import io.jsonwebtoken.Claims;
import io.jsonwebtoken.ExpiredJwtException;
import io.jsonwebtoken.IncorrectClaimException;
import io.jsonwebtoken.Jws;
import io.jsonwebtoken.JwtException;
import io.jsonwebtoken.Jwts;
import io.jsonwebtoken.MissingClaimException;
import io.jsonwebtoken.security.SignatureException;
import lombok.extern.slf4j.Slf4j;
import org.springframework.stereotype.Component;

import java.io.IOException;
import java.io.UncheckedIOException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.security.GeneralSecurityException;
import java.security.KeyFactory;
import java.security.PublicKey;
import java.security.spec.X509EncodedKeySpec;
import java.util.Base64;
import java.util.Set;
import java.util.UUID;

/**
 * Valida o JWT RS256 emitido pelo Identity: assinatura com a chave publica, iss, aud, exp
 * (tolerancia de 30 s) e os claims principal_type/cargo. Nao consulta banco.
 */
@Slf4j
@Component
public class JwtTokenValidator {

    static final long TOLERANCIA_SEGUNDOS = 30;
    static final Set<String> CARGOS = Set.of("ATENDENTE", "MECANICO", "ALMOXARIFE");

    private final JwtProperties properties;
    private final PublicKey chavePublica;

    public JwtTokenValidator(JwtProperties properties) {
        this.properties = properties;
        this.chavePublica = carregarChave(properties.publicKey());
        if (chavePublica == null) {
            log.atWarn().addKeyValue("event", "jwt_chave_publica_ausente")
                    .log("app.security.jwt.public-key vazio: todo token sera rejeitado");
        }
    }

    public UsuarioAutenticado validar(String token) {
        if (chavePublica == null) {
            throw new TokenInvalidoException("chave_publica_ausente");
        }
        Claims claims = verificar(token).getPayload();
        return montarUsuario(claims);
    }

    private Jws<Claims> verificar(String token) {
        try {
            Jws<Claims> jws = Jwts.parser()
                    .verifyWith(chavePublica)
                    .requireIssuer(properties.issuer())
                    .requireAudience(properties.audience())
                    .clockSkewSeconds(TOLERANCIA_SEGUNDOS)
                    .build()
                    .parseSignedClaims(token);
            if (!"RS256".equals(jws.getHeader().getAlgorithm())) {
                throw new TokenInvalidoException("algoritmo_invalido");
            }
            return jws;
        } catch (ExpiredJwtException e) {
            throw new TokenInvalidoException("expirado");
        } catch (SignatureException e) {
            throw new TokenInvalidoException("assinatura_invalida");
        } catch (MissingClaimException | IncorrectClaimException e) {
            throw new TokenInvalidoException("claim_invalido_" + e.getClaimName());
        } catch (JwtException | IllegalArgumentException e) {
            throw new TokenInvalidoException("malformado");
        }
    }

    private UsuarioAutenticado montarUsuario(Claims claims) {
        UUID sub;
        try {
            sub = UUID.fromString(claims.getSubject());
        } catch (IllegalArgumentException | NullPointerException e) {
            throw new TokenInvalidoException("sub_invalido");
        }

        UsuarioAutenticado.TipoPrincipal tipo;
        try {
            tipo = UsuarioAutenticado.TipoPrincipal.valueOf(claims.get("principal_type", String.class));
        } catch (IllegalArgumentException | NullPointerException e) {
            throw new TokenInvalidoException("principal_type_invalido");
        }

        String cargo = claims.get("cargo", String.class);
        if (tipo == UsuarioAutenticado.TipoPrincipal.FUNCIONARIO) {
            if (cargo == null || !CARGOS.contains(cargo)) {
                throw new TokenInvalidoException("cargo_invalido");
            }
            return new UsuarioAutenticado(sub, tipo, cargo);
        }
        return new UsuarioAutenticado(sub, tipo, null);
    }

    static PublicKey carregarChave(String valor) {
        if (valor == null || valor.isBlank()) {
            return null;
        }
        String pem = valor.startsWith("file:") ? lerArquivo(valor.substring("file:".length())) : valor;
        // Aceita o PEM com quebras de linha reais ou escapadas como \n (variavel de ambiente).
        String base64 = pem.replace("\\n", "\n")
                .replace("-----BEGIN PUBLIC KEY-----", "")
                .replace("-----END PUBLIC KEY-----", "")
                .replaceAll("\\s", "");
        try {
            return KeyFactory.getInstance("RSA")
                    .generatePublic(new X509EncodedKeySpec(Base64.getDecoder().decode(base64)));
        } catch (GeneralSecurityException | IllegalArgumentException e) {
            throw new IllegalStateException("app.security.jwt.public-key nao e uma chave publica RSA em PEM", e);
        }
    }

    private static String lerArquivo(String caminho) {
        try {
            return Files.readString(Path.of(caminho));
        } catch (IOException e) {
            throw new UncheckedIOException("Nao foi possivel ler a chave publica em " + caminho, e);
        }
    }
}
