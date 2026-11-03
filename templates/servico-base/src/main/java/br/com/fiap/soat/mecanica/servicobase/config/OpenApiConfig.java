package br.com.fiap.soat.mecanica.servicobase.config;

import io.swagger.v3.oas.models.Components;
import io.swagger.v3.oas.models.OpenAPI;
import io.swagger.v3.oas.models.info.Info;
import io.swagger.v3.oas.models.security.SecurityRequirement;
import io.swagger.v3.oas.models.security.SecurityScheme;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;

/**
 * Documento OpenAPI do servico. Atras do Traefik (StripPrefix), o server do documento vem do
 * X-Forwarded-Prefix, tratado pelo Spring com server.forward-headers-strategy=framework.
 */
@Configuration
public class OpenApiConfig {

    @Bean
    public OpenAPI customOpenAPI(
            @Value("${spring.application.name}") String nome,
            @Value("${app.versao:dev}") String versao) {
        return new OpenAPI()
                .info(new Info().title(nome).version(versao))
                .components(new Components()
                        .addSecuritySchemes("bearerAuth",
                                new SecurityScheme()
                                        .type(SecurityScheme.Type.HTTP)
                                        .scheme("bearer")
                                        .bearerFormat("JWT")
                        )
                )
                .addSecurityItem(new SecurityRequirement().addList("bearerAuth"));
    }
}
