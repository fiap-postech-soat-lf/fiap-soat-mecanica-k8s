package br.com.fiap.soat.mecanica.servicobase.support;

import org.springframework.test.context.ActiveProfiles;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.springframework.test.context.DynamicPropertySource;
// [SQL]
import org.testcontainers.containers.PostgreSQLContainer;
import org.testcontainers.utility.DockerImageName;
// [/SQL]

/**
 * Base dos testes de integracao. Os containers sao estaticos e iniciados uma vez por JVM
 * (reaproveitados por todas as classes de teste), para o build ficar abaixo de ~3 min.
 */
@ActiveProfiles("test")
public abstract class IntegracaoTest {

    // [SQL]
    static final PostgreSQLContainer<?> POSTGRES =
            new PostgreSQLContainer<>(DockerImageName.parse("postgres:17-alpine"))
                    .withDatabaseName("servicobase_test")
                    .withUsername("postgres")
                    .withPassword("postgres");
    // [/SQL]

    static {
        // [SQL]
        POSTGRES.start();
        // [/SQL]
    }

    @DynamicPropertySource
    static void registrarPropriedades(DynamicPropertyRegistry registry) {
        registry.add("app.security.jwt.public-key", JwtTestTokens::chavePublicaPem);
        // [SQL]
        registry.add("spring.datasource.url", POSTGRES::getJdbcUrl);
        registry.add("spring.datasource.username", POSTGRES::getUsername);
        registry.add("spring.datasource.password", POSTGRES::getPassword);
        // [/SQL]
    }
}
