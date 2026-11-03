package br.com.fiap.soat.mecanica.servicobase.adapters.in.messaging;

import br.com.fiap.soat.mecanica.servicobase.application.mensageria.MensagemEnvelope;
import br.com.fiap.soat.mecanica.servicobase.application.mensageria.ProcessadorMensagem;
import br.com.fiap.soat.mecanica.servicobase.config.observability.Mdc;
import br.com.fiap.soat.mecanica.servicobase.support.IntegracaoTest;
import com.fasterxml.jackson.databind.ObjectMapper;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.slf4j.MDC;
import org.springframework.beans.factory.annotation.Autowired;

import java.time.Instant;
import java.util.List;
import java.util.Map;
import java.util.UUID;
import java.util.concurrent.CopyOnWriteArrayList;

import static org.assertj.core.api.Assertions.assertThat;
import static org.awaitility.Awaitility.await;

/**
 * Consumidor com uma fila propria e um ProcessadorMensagem de teste (independe da variante SQL/DynamoDB).
 * A idempotencia ponta a ponta fica no ProcessadorMensagemSqlIT.
 */
class SqsConsumidorIT extends IntegracaoTest {

    @Autowired
    private ObjectMapper objectMapper;

    private final List<MensagemEnvelope> processadas = new CopyOnWriteArrayList<>();
    private final List<Map<String, String>> mdcDurante = new CopyOnWriteArrayList<>();
    private volatile boolean falhar;
    private String fila;
    private SqsConsumidor consumidor;

    @BeforeEach
    void iniciar() {
        fila = criarFila("consumidor");
        ProcessadorMensagem processador = envelope -> {
            mdcDurante.add(MDC.getCopyOfContextMap());
            processadas.add(envelope);
            if (falhar) {
                throw new IllegalStateException("falha de teste");
            }
        };
        consumidor = new SqsConsumidor(SQS, objectMapper, processador, List.of(fila), 1, 30);
        consumidor.start();
    }

    @AfterEach
    void parar() {
        consumidor.stop();
        SQS.deleteQueue(r -> r.queueUrl(fila));
    }

    @Test
    void sucessoApagaAMensagemEAbreOMdcComOContextoDoEnvelope() throws Exception {
        MensagemEnvelope envelope = envelope();
        enviar(objectMapper.writeValueAsString(envelope));

        await().until(() -> processadas.size() == 1 && mensagensNaFila(fila) == 0);

        assertThat(processadas.getFirst()).isEqualTo(envelope);
        assertThat(mdcDurante.getFirst())
                .containsEntry(Mdc.CORRELATION_ID, "corr-consumidor")
                .containsEntry(Mdc.MESSAGE_ID, envelope.messageId().toString())
                .containsEntry(Mdc.SAGA_ID, envelope.sagaId().toString())
                .doesNotContainKey(Mdc.OS_ID);
    }

    @Test
    void falhaNoProcessamentoNaoApagaAMensagem() throws Exception {
        falhar = true;
        enviar(objectMapper.writeValueAsString(envelope()));

        await().until(() -> processadas.size() == 1);

        assertThat(mensagensEmVoo(fila)).isEqualTo(1);
    }

    @Test
    void jsonInvalidoNaoChegaNoProcessadorENaoEApagado() {
        enviar("isto nao e json");

        await().until(() -> mensagensEmVoo(fila) == 1);

        assertThat(processadas).isEmpty();
    }

    @Test
    void stopEncerraOsLacos() {
        assertThat(consumidor.isRunning()).isTrue();

        consumidor.stop();

        assertThat(consumidor.isRunning()).isFalse();
    }

    @Test
    void semProcessadorOuSemFilasNaoInicia() {
        SqsConsumidor semProcessador = new SqsConsumidor(SQS, objectMapper, (ProcessadorMensagem) null, List.of(fila), 1, 30);
        SqsConsumidor semFilas = new SqsConsumidor(SQS, objectMapper, envelope -> { }, List.of(""), 1, 30);

        semProcessador.start();
        semFilas.start();

        assertThat(semProcessador.isRunning()).isFalse();
        assertThat(semFilas.isRunning()).isFalse();
    }

    private void enviar(String corpo) {
        SQS.sendMessage(r -> r.queueUrl(fila).messageBody(corpo));
    }

    private MensagemEnvelope envelope() {
        return new MensagemEnvelope(UUID.randomUUID(), "TesteConsumidor", 1, UUID.randomUUID(), null,
                "corr-consumidor", null, Instant.parse("2026-11-02T12:00:00Z"), null,
                objectMapper.createObjectNode().put("campo", "valor"));
    }
}
