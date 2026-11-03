package br.com.fiap.soat.mecanica.servicobase.adapters.in.web.security;

import jakarta.servlet.FilterChain;
import jakarta.servlet.ServletException;
import jakarta.servlet.http.HttpServletRequest;
import jakarta.servlet.http.HttpServletResponse;
import lombok.RequiredArgsConstructor;
import lombok.extern.slf4j.Slf4j;
import org.springframework.security.authentication.UsernamePasswordAuthenticationToken;
import org.springframework.security.core.GrantedAuthority;
import org.springframework.security.core.authority.SimpleGrantedAuthority;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.web.filter.OncePerRequestFilter;

import java.io.IOException;
import java.util.ArrayList;
import java.util.List;

/**
 * Autentica a requisicao a partir do JWT do header Authorization. Sem token ou com token invalido,
 * segue sem autenticar e o Spring Security decide 401/403. Os headers x-user-* injetados pelo
 * authorizer sao ignorados: o servico valida o JWT por conta propria (defesa em profundidade).
 * Instanciado pelo SecurityConfig (nao e @Component, para nao virar filtro do servlet tambem).
 */
@Slf4j
@RequiredArgsConstructor
public class JwtAuthenticationFilter extends OncePerRequestFilter {

    private static final String PREFIXO = "Bearer ";

    private final JwtTokenValidator validator;

    @Override
    protected void doFilterInternal(HttpServletRequest request, HttpServletResponse response, FilterChain filterChain)
            throws ServletException, IOException {
        String authHeader = request.getHeader("Authorization");

        if (authHeader != null && authHeader.startsWith(PREFIXO)
                && SecurityContextHolder.getContext().getAuthentication() == null) {
            autenticar(authHeader.substring(PREFIXO.length()).trim());
        }

        filterChain.doFilter(request, response);
    }

    private void autenticar(String token) {
        try {
            UsuarioAutenticado usuario = validator.validar(token);
            UsernamePasswordAuthenticationToken authentication =
                    new UsernamePasswordAuthenticationToken(usuario, null, authorities(usuario));
            SecurityContextHolder.getContext().setAuthentication(authentication);
        } catch (TokenInvalidoException e) {
            log.atInfo().addKeyValue("event", "jwt_invalido")
                    .addKeyValue("motivo", e.motivo()).log("JWT rejeitado");
        }
    }

    static List<GrantedAuthority> authorities(UsuarioAutenticado usuario) {
        List<GrantedAuthority> authorities = new ArrayList<>();
        authorities.add(new SimpleGrantedAuthority("ROLE_" + usuario.principalType().name()));
        if (usuario.cargo() != null) {
            authorities.add(new SimpleGrantedAuthority("ROLE_" + usuario.cargo()));
        }
        return authorities;
    }
}
