package br.com.fiap.soat.mecanica.servicobase.adapters.out.persistence.mensageria;

import br.com.fiap.soat.mecanica.servicobase.adapters.out.messaging.DestinosMensageria;
import br.com.fiap.soat.mecanica.servicobase.application.mensageria.MensagemEnvelope;
import br.com.fiap.soat.mecanica.servicobase.application.mensageria.OutboxPort;
import com.fasterxml.jackson.core.JsonProcessingException;
import com.fasterxml.jackson.databind.ObjectMapper;
import org.springframework.stereotype.Component;
import org.springframework.transaction.annotation.Propagation;
import org.springframework.transaction.annotation.Transactional;

import java.time.Instant;
import java.util.UUID;

/**
 * Grava a mensagem na tabela outbox dentro da transacao do caso de uso (MANDATORY: falha sem transacao).
 * O destino e validado aqui, para um nome errado falhar no caso de uso e nao so na publicacao.
 */
@Component
public class OutboxSqlAdapter implements OutboxPort {

    private final OutboxJpaRepository repository;
    private final DestinosMensageria destinos;
    private final ObjectMapper objectMapper;

    public OutboxSqlAdapter(OutboxJpaRepository repository, DestinosMensageria destinos, ObjectMapper objectMapper) {
        this.repository = repository;
        this.destinos = destinos;
        this.objectMapper = objectMapper;
    }

    @Override
    @Transactional(propagation = Propagation.MANDATORY)
    public void registrar(String destino, MensagemEnvelope envelope) {
        destinos.resolver(destino);
        OutboxEntity entity = new OutboxEntity();
        entity.setId(UUID.randomUUID());
        entity.setMessageId(envelope.messageId());
        entity.setDestino(destino);
        entity.setTipo(envelope.type());
        entity.setEnvelope(serializar(envelope));
        entity.setCriadoEm(Instant.now());
        repository.save(entity);
    }

    private String serializar(MensagemEnvelope envelope) {
        try {
            return objectMapper.writeValueAsString(envelope);
        } catch (JsonProcessingException e) {
            throw new IllegalArgumentException("Envelope nao serializavel: " + envelope.type(), e);
        }
    }
}
