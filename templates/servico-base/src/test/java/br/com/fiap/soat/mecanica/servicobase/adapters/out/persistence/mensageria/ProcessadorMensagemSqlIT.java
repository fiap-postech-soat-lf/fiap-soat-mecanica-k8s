package br.com.fiap.soat.mecanica.servicobase.adapters.out.persistence.mensageria;

import br.com.fiap.soat.mecanica.servicobase.application.mensageria.MensagemEnvelope;
import br.com.fiap.soat.mecanica.servicobase.application.mensageria.MensagemFactory;
import br.com.fiap.soat.mecanica.servicobase.application.mensageria.OutboxPort;
import br.com.fiap.soat.mecanica.servicobase.support.HandlerDeTeste;
import br.com.fiap.soat.mecanica.servicobase.support.IntegracaoTest;
import com.fasterxml.jackson.databind.ObjectMapper;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;

import java.time.Duration;
import java.time.Instant;
import java.util.Map;
import java.util.UUID;
import java.util.concurrent.atomic.AtomicReference;
import java.util.function.Consumer;

import static org.assertj.core.api.Assertions.assertThat;
import static org.awaitility.Awaitility.await;

/** Ponta a ponta: fila de entrada → SqsConsumidor da aplicacao → ProcessadorMensagemSql → handler. */
class ProcessadorMensagemSqlIT extends IntegracaoTest {

    @Autowired
    private HandlerDeTeste handler;

    @Autowired
    private MensagemProcessadaJpaRepository processadas;

    @Autowired
    private OutboxJpaRepository outboxRepository;

    @Autowired
    private OutboxPort outbox;

    @Autowired
    private MensagemFactory factory;

    @Autowired
    private ObjectMapper objectMapper;

    @AfterEach
    void reiniciarHandler() {
        handler.reiniciar();
    }

    @Test
    void mesmaMensagemEntregueDuasVezesExecutaOHandlerUmaVez() throws Exception {
        MensagemEnvelope envelope = envelope(HandlerDeTeste.TIPO);
        String corpo = objectMapper.writeValueAsString(envelope);

        enviar(corpo);
        enviar(corpo);

        await().until(() -> mensagensNaFila(MENSAGERIA.filaEntrada()) == 0
                && processadas.existsById(envelope.messageId()));
        assertThat(handler.chamadas(envelope.messageId())).hasSize(1);
        assertThat(handler.chamadas(envelope.messageId()).getFirst().correlationIdNoMdc())
                .isEqualTo(envelope.correlationId());
    }

    @Test
    void falhaNoHandlerDesfazOutboxEIdempotenciaENaoApagaAMensagem() throws Exception {
        MensagemEnvelope envelope = envelope(HandlerDeTeste.TIPO);
        AtomicReference<UUID> resposta = new AtomicReference<>();
        handler.quandoProcessar(doTeste(envelope, recebida -> {
            MensagemEnvelope saida = factory.criar("TesteResposta", 1, Map.of());
            resposta.set(saida.messageId());
            outbox.registrar("teste-eventos", saida);
            throw new IllegalStateException("falha de teste depois de escrever na outbox");
        }));

        enviar(objectMapper.writeValueAsString(envelope));

        await().until(() -> !handler.chamadas(envelope.messageId()).isEmpty());
        await().pollDelay(Duration.ofSeconds(1)).until(() -> true);
        assertThat(processadas.existsById(envelope.messageId())).isFalse();
        assertThat(outboxRepository.existsByMessageId(resposta.get())).isFalse();
        assertThat(mensagensNaFila(MENSAGERIA.filaEntrada())).isEqualTo(1);
    }

    @Test
    void respostaRegistradaPeloHandlerHerdaOContextoEEPublicada() throws Exception {
        MensagemEnvelope envelope = envelope(HandlerDeTeste.TIPO);
        AtomicReference<UUID> resposta = new AtomicReference<>();
        handler.quandoProcessar(doTeste(envelope, recebida -> {
            MensagemEnvelope saida = factory.criar("TesteResposta", 1, Map.of("ok", true));
            resposta.set(saida.messageId());
            outbox.registrar("teste-eventos", saida);
        }));

        enviar(objectMapper.writeValueAsString(envelope));

        MensagemEnvelope publicada = aguardarNaFilaAssinante(resposta);
        assertThat(publicada.causationId()).isEqualTo(envelope.messageId());
        assertThat(publicada.correlationId()).isEqualTo(envelope.correlationId());
        assertThat(publicada.sagaId()).isEqualTo(envelope.sagaId());
        assertThat(publicada.osId()).isEqualTo(envelope.osId());
    }

    @Test
    void tipoSemHandlerEConcluidoSemEfeito() throws Exception {
        MensagemEnvelope envelope = envelope("TipoDeOutroServico");

        enviar(objectMapper.writeValueAsString(envelope));

        await().until(() -> processadas.existsById(envelope.messageId()));
        await().until(() -> mensagensNaFila(MENSAGERIA.filaEntrada()) == 0);
        assertThat(handler.chamadas(envelope.messageId())).isEmpty();
    }

    /**
     * A acao so vale para a mensagem do proprio teste: a mensagem que falhou num teste anterior volta para
     * a fila depois do visibility timeout e passaria pela acao do teste atual.
     */
    private static Consumer<MensagemEnvelope> doTeste(MensagemEnvelope doTeste, Consumer<MensagemEnvelope> acao) {
        return recebida -> {
            if (recebida.messageId().equals(doTeste.messageId())) {
                acao.accept(recebida);
            }
        };
    }

    private MensagemEnvelope aguardarNaFilaAssinante(AtomicReference<UUID> messageId) {
        AtomicReference<MensagemEnvelope> encontrada = new AtomicReference<>();
        await().until(() -> {
            receber(MENSAGERIA.filaAssinante()).forEach(m -> {
                MensagemEnvelope recebida = ler(m.body());
                if (recebida.messageId().equals(messageId.get())) {
                    encontrada.set(recebida);
                }
            });
            return encontrada.get() != null;
        });
        return encontrada.get();
    }

    private MensagemEnvelope ler(String corpo) {
        try {
            return objectMapper.readValue(corpo, MensagemEnvelope.class);
        } catch (Exception e) {
            throw new IllegalStateException(e);
        }
    }

    private void enviar(String corpo) {
        SQS.sendMessage(r -> r.queueUrl(MENSAGERIA.filaEntrada()).messageBody(corpo));
    }

    private MensagemEnvelope envelope(String tipo) {
        return new MensagemEnvelope(UUID.randomUUID(), tipo, 1, UUID.randomUUID(), UUID.randomUUID(),
                "corr-" + UUID.randomUUID(), null, Instant.now(), null, objectMapper.createObjectNode());
    }
}
