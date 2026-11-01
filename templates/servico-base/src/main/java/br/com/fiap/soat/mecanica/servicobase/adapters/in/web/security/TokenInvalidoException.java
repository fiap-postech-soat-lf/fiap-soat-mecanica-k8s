package br.com.fiap.soat.mecanica.servicobase.adapters.in.web.security;

/** Token rejeitado pelo {@link JwtTokenValidator}. O motivo vai para o log; o token, nunca. */
public class TokenInvalidoException extends RuntimeException {

    private final String motivo;

    public TokenInvalidoException(String motivo) {
        super(motivo);
        this.motivo = motivo;
    }

    public String motivo() {
        return motivo;
    }
}
