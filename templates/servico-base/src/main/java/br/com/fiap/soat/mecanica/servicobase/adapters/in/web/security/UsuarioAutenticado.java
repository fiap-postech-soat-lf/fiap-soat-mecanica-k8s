package br.com.fiap.soat.mecanica.servicobase.adapters.in.web.security;

import org.springframework.security.core.Authentication;
import org.springframework.security.core.context.SecurityContextHolder;

import java.util.Optional;
import java.util.UUID;

/**
 * Principal autenticado a partir do JWT.
 *
 * @param sub           UUID do cliente ou do funcionario
 * @param principalType CLIENTE ou FUNCIONARIO
 * @param cargo         ATENDENTE, MECANICO ou ALMOXARIFE (so para FUNCIONARIO; null para CLIENTE)
 */
public record UsuarioAutenticado(UUID sub, TipoPrincipal principalType, String cargo) {

    public enum TipoPrincipal { CLIENTE, FUNCIONARIO }

    public boolean isCliente() {
        return principalType == TipoPrincipal.CLIENTE;
    }

    /** Usuario da requisicao atual, se houver (ex.: checar clienteId == sub na F6). */
    public static Optional<UsuarioAutenticado> atual() {
        Authentication authentication = SecurityContextHolder.getContext().getAuthentication();
        if (authentication != null && authentication.getPrincipal() instanceof UsuarioAutenticado usuario) {
            return Optional.of(usuario);
        }
        return Optional.empty();
    }
}
