package br.com.fiap.soat.mecanica.servicobase.config.exception;

import br.com.fiap.soat.mecanica.servicobase.config.observability.Mdc;

import java.util.List;
import java.util.UUID;

public record ErrorResponse(
        int status,
        String erro,
        String mensagem,
        String campo,
        Object valorRecebido,
        List<String> detalhes,
        String errorId
) {
    public ErrorResponse {
        if (errorId == null) {
            String correlationId = Mdc.correlationId();
            errorId = correlationId == null ? UUID.randomUUID().toString() : correlationId;
        }
    }

    public ErrorResponse(int status, String erro, String mensagem, String campo, Object valorRecebido,
                         List<String> detalhes) {
        this(status, erro, mensagem, campo, valorRecebido, detalhes, null);
    }

    public static ErrorResponse naoAutenticado() {
        return new ErrorResponse(401, "Unauthorized", "Autenticação necessária", null, null, null);
    }

    public static ErrorResponse acessoNegado() {
        return new ErrorResponse(403, "Forbidden", "Você não tem permissão para acessar este recurso",
                null, null, null);
    }
}
