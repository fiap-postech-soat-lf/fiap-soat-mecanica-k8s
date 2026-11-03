package br.com.fiap.soat.mecanica.servicobase.adapters.out.messaging;

import br.com.fiap.soat.mecanica.servicobase.support.IntegracaoTest;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import software.amazon.awssdk.services.sqs.model.Message;

import java.util.ArrayList;
import java.util.List;
import java.util.Map;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.awaitility.Awaitility.await;

class SnsSqsPublicadorIT extends IntegracaoTest {

    @Autowired
    private SnsSqsPublicador publicador;

    @Test
    void urlDeFilaPublicaDiretoNoSqsComOAtributoType() {
        publicador.publicar("teste-comandos", "ReservarPecas", "{\"messageId\":\"direto\"}");

        List<Message> recebidas = new ArrayList<>();
        await().untilAsserted(() -> {
            recebidas.addAll(receber(MENSAGERIA.filaComandos()));
            assertThat(recebidas).isNotEmpty();
        });
        assertThat(recebidas.getFirst().body()).isEqualTo("{\"messageId\":\"direto\"}");
        assertThat(recebidas.getFirst().messageAttributes().get("type").stringValue()).isEqualTo("ReservarPecas");
    }

    @Test
    void destinoNaoConfiguradoFalha() {
        assertThatThrownBy(() -> publicador.publicar("nao-existe", "X", "{}"))
                .isInstanceOf(IllegalStateException.class)
                .hasMessageContaining("app.messaging.destinos.nao-existe");
    }

    @Test
    void destinoQueNaoEArnNemUrlFalha() {
        SnsSqsPublicador comDestinoInvalido =
                new SnsSqsPublicador(SNS, SQS, new DestinosMensageria(Map.of("errado", "mecanica-os-eventos")));

        assertThatThrownBy(() -> comDestinoInvalido.publicar("errado", "X", "{}"))
                .isInstanceOf(IllegalStateException.class)
                .hasMessageContaining("nao e ARN");
    }
}
