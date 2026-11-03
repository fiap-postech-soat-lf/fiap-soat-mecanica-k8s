package br.com.fiap.soat.mecanica.servicobase.support;

import br.com.fiap.soat.mecanica.servicobase.adapters.in.web.security.UsuarioAutenticado;
import org.springframework.boot.test.context.TestConfiguration;
import org.springframework.context.annotation.Bean;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RestController;

/** Beans de teste do contexto compartilhado pelos ITs (ver {@link IntegracaoTest}). */
@TestConfiguration(proxyBeanMethods = false)
public class ComponentesDeTeste {

    @Bean
    HandlerDeTeste handlerDeTeste() {
        return new HandlerDeTeste();
    }

    /** Rota que exige cargo, usada pelo SegurancaIT (registrada por ser classe membro desta configuracao). */
    @RestController
    static class RotaDeTeste {

        @GetMapping("/teste/mecanico")
        @PreAuthorize("hasRole('MECANICO')")
        String mecanico() {
            return UsuarioAutenticado.atual().orElseThrow().sub().toString();
        }
    }
}
