package br.com.fiap.soat.mecanica.servicobase.application.mensageria;

import br.com.fiap.soat.mecanica.servicobase.config.observability.Mdc;
import com.fasterxml.jackson.databind.ObjectMapper;
import io.opentelemetry.api.trace.Span;
import io.opentelemetry.api.trace.SpanContext;
import org.slf4j.MDC;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.stereotype.Component;

import java.time.Clock;
import java.util.UUID;

/**
 * Cria envelopes com messageId novo e o contexto da execucao atual: correlationId do MDC (requisicao
 * HTTP ou mensagem em processamento), causationId = messageId da mensagem em processamento e
 * traceparent do span atual (nulo sem o agente OpenTelemetry).
 */
@Component
public class MensagemFactory {

    private final ObjectMapper objectMapper;
    private final Clock clock;

    @Autowired
    public MensagemFactory(ObjectMapper objectMapper) {
        this(objectMapper, Clock.systemUTC());
    }

    MensagemFactory(ObjectMapper objectMapper, Clock clock) {
        this.objectMapper = objectMapper;
        this.clock = clock;
    }

    public MensagemEnvelope criar(String tipo, int versao, UUID sagaId, UUID osId, Object payload) {
        return new MensagemEnvelope(
                UUID.randomUUID(),
                tipo,
                versao,
                sagaId,
                osId,
                correlationId(),
                uuidDoMdc(Mdc.MESSAGE_ID),
                clock.instant(),
                traceparent(),
                objectMapper.valueToTree(payload));
    }

    /** Igual a {@link #criar(String, int, UUID, UUID, Object)}, herdando sagaId e osId da mensagem em processamento. */
    public MensagemEnvelope criar(String tipo, int versao, Object payload) {
        return criar(tipo, versao, uuidDoMdc(Mdc.SAGA_ID), uuidDoMdc(Mdc.OS_ID), payload);
    }

    private static String correlationId() {
        String atual = Mdc.correlationId();
        return atual != null ? atual : UUID.randomUUID().toString();
    }

    private static UUID uuidDoMdc(String chave) {
        String valor = MDC.get(chave);
        if (valor == null) {
            return null;
        }
        try {
            return UUID.fromString(valor);
        } catch (IllegalArgumentException e) {
            return null;
        }
    }

    private static String traceparent() {
        SpanContext span = Span.current().getSpanContext();
        if (!span.isValid()) {
            return null;
        }
        return "00-" + span.getTraceId() + "-" + span.getSpanId() + "-" + span.getTraceFlags().asHex();
    }
}
