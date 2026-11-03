package br.com.fiap.soat.mecanica.servicobase.config;

import br.com.fiap.soat.mecanica.servicobase.adapters.in.web.security.JwtAuthenticationFilter;
import br.com.fiap.soat.mecanica.servicobase.adapters.in.web.security.JwtTokenValidator;
import br.com.fiap.soat.mecanica.servicobase.config.exception.ErrorResponse;
import com.fasterxml.jackson.databind.ObjectMapper;
import jakarta.servlet.http.HttpServletResponse;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.http.MediaType;
import org.springframework.security.config.annotation.method.configuration.EnableMethodSecurity;
import org.springframework.security.config.annotation.web.builders.HttpSecurity;
import org.springframework.security.config.annotation.web.configuration.EnableWebSecurity;
import org.springframework.security.config.annotation.web.configurers.AbstractHttpConfigurer;
import org.springframework.security.config.http.SessionCreationPolicy;
import org.springframework.security.web.SecurityFilterChain;
import org.springframework.security.web.authentication.UsernamePasswordAuthenticationFilter;

import java.io.IOException;

/**
 * Publicas: so health e Swagger. Todo o resto exige JWT valido. Sem autenticacao responde 401 e
 * sem permissao responde 403, os dois no formato ErrorResponse.
 */
@Configuration
@EnableWebSecurity
@EnableMethodSecurity
public class SecurityConfig {

    static final String[] ROTAS_PUBLICAS = {
            "/actuator/health/**",
            "/v3/api-docs/**",
            "/swagger-ui/**",
            "/swagger-ui.html",
            "/error"
    };

    /**
     * API stateless: a autenticacao e so pelo bearer token no header Authorization, sem cookie de sessao,
     * entao o navegador nao envia credencial automaticamente e nao ha o que um ataque CSRF explorar.
     * Por isso o CSRF fica desligado (java:S4502 revisada).
     */
    @Bean
    @SuppressWarnings("java:S4502")
    public SecurityFilterChain securityFilterChain(HttpSecurity http, JwtTokenValidator validator,
                                                   ObjectMapper objectMapper) throws Exception {
        return http
                .csrf(AbstractHttpConfigurer::disable)
                .httpBasic(AbstractHttpConfigurer::disable)
                .formLogin(AbstractHttpConfigurer::disable)
                .sessionManagement(session -> session.sessionCreationPolicy(SessionCreationPolicy.STATELESS))
                .authorizeHttpRequests(auth -> auth
                        .requestMatchers(ROTAS_PUBLICAS).permitAll()
                        .anyRequest().authenticated()
                )
                .exceptionHandling(ex -> ex
                        .authenticationEntryPoint((request, response, e) ->
                                escrever(response, objectMapper, ErrorResponse.naoAutenticado()))
                        .accessDeniedHandler((request, response, e) ->
                                escrever(response, objectMapper, ErrorResponse.acessoNegado()))
                )
                .addFilterBefore(new JwtAuthenticationFilter(validator), UsernamePasswordAuthenticationFilter.class)
                .build();
    }

    private static void escrever(HttpServletResponse response, ObjectMapper objectMapper, ErrorResponse erro)
            throws IOException {
        response.setStatus(erro.status());
        response.setContentType(MediaType.APPLICATION_JSON_VALUE);
        response.setCharacterEncoding("UTF-8");
        objectMapper.writeValue(response.getOutputStream(), erro);
    }
}
