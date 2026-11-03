package br.com.fiap.soat.mecanica.servicobase.application.mensageria;

import com.fasterxml.jackson.annotation.JsonFormat;
import com.fasterxml.jackson.annotation.JsonInclude;
import com.fasterxml.jackson.databind.JsonNode;

import java.time.Instant;
import java.util.UUID;

/**
 * Envelope comum de todas as mensagens (contrato em docs/contratos/envelope.schema.json).
 * Campos opcionais nulos nao sao serializados, porque o schema nao aceita null, e o occurredAt sai
 * sempre como texto ISO-8601, qualquer que seja a configuracao do ObjectMapper.
 */
@JsonInclude(JsonInclude.Include.NON_NULL)
public record MensagemEnvelope(
        UUID messageId,
        String type,
        int version,
        UUID sagaId,
        UUID osId,
        String correlationId,
        UUID causationId,
        @JsonFormat(shape = JsonFormat.Shape.STRING) Instant occurredAt,
        String traceparent,
        JsonNode payload) {
}
