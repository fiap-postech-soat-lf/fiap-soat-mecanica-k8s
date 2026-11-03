package br.com.fiap.soat.mecanica.servicobase.adapters.in.web.security;

import br.com.fiap.soat.mecanica.servicobase.support.IntegracaoTest;
import br.com.fiap.soat.mecanica.servicobase.support.JwtTestTokens;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.autoconfigure.web.servlet.AutoConfigureMockMvc;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.context.annotation.Import;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.test.web.servlet.MockMvc;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RestController;

import java.time.Instant;
import java.util.UUID;

import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.content;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.header;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.jsonPath;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

@SpringBootTest
@AutoConfigureMockMvc
@Import(SegurancaIT.RotaDeTeste.class)
class SegurancaIT extends IntegracaoTest {

    @Autowired
    private MockMvc mockMvc;

    @Test
    void healthEhPublico() throws Exception {
        mockMvc.perform(get("/actuator/health"))
                .andExpect(status().isOk())
                .andExpect(header().exists("X-Correlation-Id"));
    }

    @Test
    void documentoOpenApiEhPublico() throws Exception {
        mockMvc.perform(get("/v3/api-docs"))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.info.title").value("mecanica-servicobase"));
    }

    @Test
    void rotaProtegidaSemTokenResponde401EmJson() throws Exception {
        mockMvc.perform(get("/qualquer-rota").header("X-Correlation-Id", "corr-401"))
                .andExpect(status().isUnauthorized())
                .andExpect(content().contentTypeCompatibleWith("application/json"))
                .andExpect(jsonPath("$.status").value(401))
                .andExpect(jsonPath("$.errorId").value("corr-401"));
    }

    @Test
    void tokenExpiradoResponde401() throws Exception {
        String token = JwtTestTokens.token().expiraEm(Instant.now().minusSeconds(120)).gerar();

        mockMvc.perform(get("/qualquer-rota").header("Authorization", "Bearer " + token))
                .andExpect(status().isUnauthorized());
    }

    @Test
    void tokenDeOutroIssuerResponde401() throws Exception {
        String token = JwtTestTokens.token().issuer("outro-emissor").gerar();

        mockMvc.perform(get("/qualquer-rota").header("Authorization", "Bearer " + token))
                .andExpect(status().isUnauthorized());
    }

    @Test
    void headersDoAuthorizerSemTokenNaoAutenticam() throws Exception {
        mockMvc.perform(get("/qualquer-rota")
                        .header("x-user-sub", UUID.randomUUID().toString())
                        .header("x-user-principal-type", "FUNCIONARIO")
                        .header("x-user-cargo", "MECANICO"))
                .andExpect(status().isUnauthorized());
    }

    @Test
    void tokenValidoPassaDaSegurancaEChegaNoRoteamento() throws Exception {
        String token = JwtTestTokens.cliente(UUID.randomUUID());

        mockMvc.perform(get("/qualquer-rota").header("Authorization", "Bearer " + token))
                .andExpect(status().isNotFound());
    }

    @Test
    void funcionarioComCargoExigidoAcessaERecebeOProprioSub() throws Exception {
        UUID sub = UUID.randomUUID();
        String token = JwtTestTokens.funcionario(sub, "MECANICO");

        mockMvc.perform(get("/teste/mecanico").header("Authorization", "Bearer " + token))
                .andExpect(status().isOk())
                .andExpect(content().string(sub.toString()));
    }

    @Test
    void clienteEmRotaDeFuncionarioResponde403() throws Exception {
        String token = JwtTestTokens.cliente(UUID.randomUUID());

        mockMvc.perform(get("/teste/mecanico").header("Authorization", "Bearer " + token))
                .andExpect(status().isForbidden())
                .andExpect(jsonPath("$.status").value(403));
    }

    @RestController
    static class RotaDeTeste {

        @GetMapping("/teste/mecanico")
        @PreAuthorize("hasRole('MECANICO')")
        String mecanico() {
            return UsuarioAutenticado.atual().orElseThrow().sub().toString();
        }
    }
}
