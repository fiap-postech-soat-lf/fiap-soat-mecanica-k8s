package br.com.fiap.soat.mecanica.servicobase.adapters.in.web.security;

import br.com.fiap.soat.mecanica.servicobase.support.JwtTestTokens;
import io.jsonwebtoken.Jwts;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;

import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.time.Instant;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

class JwtTokenValidatorTest {

    private final JwtTokenValidator validator = validador(JwtTestTokens.chavePublicaPem());

    @Test
    void clienteValidoViraUsuarioSemCargo() {
        UUID sub = UUID.randomUUID();

        UsuarioAutenticado usuario = validator.validar(JwtTestTokens.cliente(sub));

        assertThat(usuario).isEqualTo(new UsuarioAutenticado(sub, UsuarioAutenticado.TipoPrincipal.CLIENTE, null));
        assertThat(usuario.isCliente()).isTrue();
        assertThat(JwtAuthenticationFilter.authorities(usuario))
                .extracting(Object::toString).containsExactly("ROLE_CLIENTE");
    }

    @Test
    void funcionarioValidoTemRoleDoCargo() {
        UUID sub = UUID.randomUUID();

        UsuarioAutenticado usuario = validator.validar(JwtTestTokens.funcionario(sub, "ALMOXARIFE"));

        assertThat(usuario.cargo()).isEqualTo("ALMOXARIFE");
        assertThat(usuario.isCliente()).isFalse();
        assertThat(JwtAuthenticationFilter.authorities(usuario))
                .extracting(Object::toString).containsExactly("ROLE_FUNCIONARIO", "ROLE_ALMOXARIFE");
    }

    @Test
    void funcionarioSemCargoOuComCargoDesconhecidoEhRejeitado() {
        assertMotivo(JwtTestTokens.token().principalType("FUNCIONARIO").gerar(), "cargo_invalido");
        assertMotivo(JwtTestTokens.token().principalType("FUNCIONARIO").cargo("GERENTE").gerar(), "cargo_invalido");
    }

    @Test
    void assinaturaDeOutraChaveEhRejeitada() {
        assertMotivo(JwtTestTokens.token().assinadoComOutraChave().gerar(), "assinatura_invalida");
    }

    @Test
    void audienceOuIssuerErradosSaoRejeitados() {
        assertMotivo(JwtTestTokens.token().audience("outra-api").gerar(), "claim_invalido_aud");
        assertMotivo(JwtTestTokens.token().issuer("outro-emissor").gerar(), "claim_invalido_iss");
    }

    @Test
    void expiradoAlemDaToleranciaEhRejeitado() {
        assertMotivo(JwtTestTokens.token().expiraEm(Instant.now().minusSeconds(60)).gerar(), "expirado");
    }

    @Test
    void expiradoDentroDaToleranciaDe30SegundosAindaVale() {
        String token = JwtTestTokens.token().expiraEm(Instant.now().minusSeconds(10)).gerar();

        assertThat(validator.validar(token)).isNotNull();
    }

    @Test
    void algoritmoDiferenteDeRs256EhRejeitado() {
        assertMotivo(JwtTestTokens.token().algoritmo(Jwts.SIG.RS512).gerar(), "algoritmo_invalido");
    }

    @Test
    void claimsObrigatoriosInvalidosSaoRejeitados() {
        assertMotivo(JwtTestTokens.token().sub("nao-e-uuid").gerar(), "sub_invalido");
        assertMotivo(JwtTestTokens.token().principalType("ADMIN").gerar(), "principal_type_invalido");
        assertMotivo(JwtTestTokens.token().principalType(null).gerar(), "principal_type_invalido");
    }

    @Test
    void tokenMalformadoEhRejeitado() {
        assertMotivo("isto.nao.e-um-jwt", "malformado");
        assertMotivo("", "malformado");
    }

    @Test
    void semChavePublicaTodoTokenEhRejeitado() {
        JwtTokenValidator semChave = validador("");

        assertThatThrownBy(() -> semChave.validar(JwtTestTokens.cliente(UUID.randomUUID())))
                .isInstanceOf(TokenInvalidoException.class)
                .hasMessage("chave_publica_ausente");
    }

    @Test
    void aceitaChaveComQuebrasDeLinhaEscapadas() {
        JwtTokenValidator escapado = validador(JwtTestTokens.chavePublicaPem().replace("\n", "\\n"));

        assertThat(escapado.validar(JwtTestTokens.cliente(UUID.randomUUID()))).isNotNull();
    }

    @Test
    void aceitaChaveLidaDeArquivo(@TempDir Path dir) throws IOException {
        Path arquivo = Files.writeString(dir.resolve("dev-public.pem"), JwtTestTokens.chavePublicaPem());

        JwtTokenValidator deArquivo = validador("file:" + arquivo);

        assertThat(deArquivo.validar(JwtTestTokens.cliente(UUID.randomUUID()))).isNotNull();
    }

    @Test
    void chaveInvalidaOuArquivoInexistenteFalhamNaInicializacao() {
        assertThatThrownBy(() -> validador("nao-e-pem"))
                .isInstanceOf(IllegalStateException.class);
        assertThatThrownBy(() -> validador("file:/caminho/que/nao/existe.pem"))
                .hasMessageContaining("/caminho/que/nao/existe.pem");
    }

    private void assertMotivo(String token, String motivo) {
        assertThatThrownBy(() -> validator.validar(token))
                .isInstanceOf(TokenInvalidoException.class)
                .satisfies(e -> assertThat(((TokenInvalidoException) e).motivo()).isEqualTo(motivo));
    }

    private static JwtTokenValidator validador(String chave) {
        return new JwtTokenValidator(new JwtProperties(chave, JwtTestTokens.ISSUER, JwtTestTokens.AUDIENCE));
    }
}
