package br.com.fiap.soat.mecanica.servicobase.application.mensageria;

import br.com.fiap.soat.mecanica.servicobase.config.observability.Mdc;
import com.fasterxml.jackson.databind.ObjectMapper;
import io.opentelemetry.api.trace.Span;
import io.opentelemetry.api.trace.SpanContext;
import io.opentelemetry.api.trace.TraceFlags;
import io.opentelemetry.api.trace.TraceState;
import io.opentelemetry.context.Scope;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.Test;
import org.slf4j.MDC;
import org.springframework.http.converter.json.Jackson2ObjectMapperBuilder;

import java.time.Clock;
import java.time.Instant;
import java.time.ZoneOffset;
import java.util.Map;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;

class MensagemFactoryTest {

    private static final Instant AGORA = Instant.parse("2026-11-02T12:00:00Z");

    private final ObjectMapper objectMapper = Jackson2ObjectMapperBuilder.json().build();
    private final MensagemFactory factory = new MensagemFactory(objectMapper, Clock.fixed(AGORA, ZoneOffset.UTC));

    @AfterEach
    void limparMdc() {
        MDC.clear();
    }

    @Test
    void herdaContextoDaMensagemEmProcessamento() {
        UUID origem = UUID.randomUUID();
        UUID sagaId = UUID.randomUUID();
        UUID osId = UUID.randomUUID();
        MDC.put(Mdc.CORRELATION_ID, "corr-123");
        MDC.put(Mdc.MESSAGE_ID, origem.toString());
        MDC.put(Mdc.SAGA_ID, sagaId.toString());
        MDC.put(Mdc.OS_ID, osId.toString());

        MensagemEnvelope envelope = factory.criar("PecasReservadas", 1, Map.of("osId", osId));

        assertThat(envelope.messageId()).isNotNull().isNotEqualTo(origem);
        assertThat(envelope.type()).isEqualTo("PecasReservadas");
        assertThat(envelope.version()).isEqualTo(1);
        assertThat(envelope.correlationId()).isEqualTo("corr-123");
        assertThat(envelope.causationId()).isEqualTo(origem);
        assertThat(envelope.sagaId()).isEqualTo(sagaId);
        assertThat(envelope.osId()).isEqualTo(osId);
        assertThat(envelope.occurredAt()).isEqualTo(AGORA);
        assertThat(envelope.payload().get("osId").asText()).isEqualTo(osId.toString());
    }

    @Test
    void semContextoGeraCorrelationIdENaoTemCausa() {
        MensagemEnvelope envelope = factory.criar("AbrirDiagnostico", 1, Map.of());

        assertThat(UUID.fromString(envelope.correlationId())).isNotNull();
        assertThat(envelope.causationId()).isNull();
        assertThat(envelope.sagaId()).isNull();
        assertThat(envelope.osId()).isNull();
        assertThat(envelope.traceparent()).isNull();
    }

    @Test
    void idsExplicitosPrevalecemSobreOMdc() {
        UUID sagaId = UUID.randomUUID();
        UUID osId = UUID.randomUUID();
        MDC.put(Mdc.SAGA_ID, UUID.randomUUID().toString());
        MDC.put(Mdc.OS_ID, UUID.randomUUID().toString());

        MensagemEnvelope envelope = factory.criar("ReservarPecas", 2, sagaId, osId, Map.of());

        assertThat(envelope.sagaId()).isEqualTo(sagaId);
        assertThat(envelope.osId()).isEqualTo(osId);
        assertThat(envelope.version()).isEqualTo(2);
    }

    @Test
    void valorDoMdcQueNaoEUuidEIgnorado() {
        MDC.put(Mdc.MESSAGE_ID, "nao-e-uuid");

        assertThat(factory.criar("X", 1, Map.of()).causationId()).isNull();
    }

    @Test
    void preencheTraceparentComOSpanAtual() {
        String traceId = "0af7651916cd43dd8448eb211c80319c";
        String spanId = "b7ad6b7169203331";
        SpanContext contexto = SpanContext.create(traceId, spanId, TraceFlags.getSampled(), TraceState.getDefault());

        try (Scope ignored = Span.wrap(contexto).makeCurrent()) {
            assertThat(factory.criar("X", 1, Map.of()).traceparent())
                    .isEqualTo("00-" + traceId + "-" + spanId + "-01");
        }
    }
}
