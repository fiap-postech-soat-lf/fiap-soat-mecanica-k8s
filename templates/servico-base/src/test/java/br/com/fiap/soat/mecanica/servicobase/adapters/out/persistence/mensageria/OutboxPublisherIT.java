package br.com.fiap.soat.mecanica.servicobase.adapters.out.persistence.mensageria;

import br.com.fiap.soat.mecanica.servicobase.application.mensageria.MensagemEnvelope;
import br.com.fiap.soat.mecanica.servicobase.application.mensageria.MensagemFactory;
import br.com.fiap.soat.mecanica.servicobase.application.mensageria.OutboxPort;
import br.com.fiap.soat.mecanica.servicobase.support.IntegracaoTest;
import com.fasterxml.jackson.databind.ObjectMapper;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.transaction.IllegalTransactionStateException;
import org.springframework.transaction.support.TransactionTemplate;
import software.amazon.awssdk.services.sqs.model.Message;

import java.time.Duration;
import java.util.List;
import java.util.Map;
import java.util.Optional;
import java.util.Set;
import java.util.UUID;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;
import java.util.stream.Collectors;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.awaitility.Awaitility.await;

class OutboxPublisherIT extends IntegracaoTest {

    @Autowired
    private OutboxPort outbox;

    @Autowired
    private OutboxJpaRepository repository;

    @Autowired
    private MensagemFactory factory;

    @Autowired
    private TransactionTemplate transacao;

    @Autowired
    private ObjectMapper objectMapper;

    @Autowired
    private JdbcTemplate jdbc;

    @Test
    void registroNaTransacaoChegaNaFilaAssinadaIgualAoEnvelope() throws Exception {
        MensagemEnvelope envelope = factory.criar("OrcamentoGerado", 1, UUID.randomUUID(), UUID.randomUUID(),
                Map.of("valorTotal", 150.25));

        transacao.executeWithoutResult(status -> outbox.registrar("teste-eventos", envelope));

        // gravado como objeto jsonb (consultavel), e nao como string JSON
        assertThat(jdbc.queryForObject("SELECT jsonb_typeof(envelope) FROM outbox WHERE message_id = ?",
                String.class, envelope.messageId())).isEqualTo("object");
        Message recebida = aguardarNaFilaAssinante(envelope.messageId());
        assertThat(objectMapper.readTree(recebida.body())).isEqualTo(objectMapper.valueToTree(envelope));
        assertThat(recebida.messageAttributes().get("type").stringValue()).isEqualTo("OrcamentoGerado");
        assertThat(objectMapper.readValue(recebida.body(), MensagemEnvelope.class)).isEqualTo(envelope);
        await().until(() -> repository.findAll().stream()
                .anyMatch(m -> m.getMessageId().equals(envelope.messageId()) && m.getPublicadoEm() != null));
    }

    @Test
    void rollbackDaTransacaoNaoPublicaNada() {
        MensagemEnvelope desfeita = factory.criar("TesteDesfeito", 1, Map.of());
        MensagemEnvelope confirmada = factory.criar("TesteConfirmado", 1, Map.of());

        transacao.executeWithoutResult(status -> {
            outbox.registrar("teste-eventos", desfeita);
            status.setRollbackOnly();
        });
        transacao.executeWithoutResult(status -> outbox.registrar("teste-eventos", confirmada));

        Set<UUID> vistas = ConcurrentHashMap.newKeySet();
        await().until(() -> {
            receber(MENSAGERIA.filaAssinante()).forEach(m -> vistas.add(messageId(m)));
            return vistas.contains(confirmada.messageId());
        });
        assertThat(vistas).doesNotContain(desfeita.messageId());
        assertThat(repository.existsByMessageId(desfeita.messageId())).isFalse();
    }

    @Test
    void registrarSemTransacaoFalha() {
        MensagemEnvelope envelope = factory.criar("X", 1, Map.of());

        assertThatThrownBy(() -> outbox.registrar("teste-eventos", envelope))
                .isInstanceOf(IllegalTransactionStateException.class);
    }

    @Test
    void destinoNaoConfiguradoFalhaNoRegistro() {
        MensagemEnvelope envelope = factory.criar("X", 1, Map.of());

        assertThatThrownBy(() -> transacao.executeWithoutResult(status -> outbox.registrar("nao-existe", envelope)))
                .isInstanceOf(IllegalStateException.class);
        assertThat(repository.existsByMessageId(envelope.messageId())).isFalse();
    }

    @Test
    void falhaNaPublicacaoIncrementaTentativasEGuardaOErro() {
        UUID messageId = registrarComCommit("teste-quebrado");
        try {
            await().untilAsserted(() -> {
                OutboxEntity linha = buscar(messageId).orElseThrow();
                assertThat(linha.getTentativas()).isPositive();
                assertThat(linha.getUltimoErro()).isNotBlank();
                assertThat(linha.getPublicadoEm()).isNull();
            });
        } finally {
            apagar(messageId);
        }
    }

    @Test
    void linhasTravadasPorUmaReplicaNaoSaoVistasPelaOutra() throws Exception {
        // teste-quebrado mantem a linha pendente mesmo com o publicador agendado rodando
        UUID messageId = registrarComCommit("teste-quebrado");
        CountDownLatch travou = new CountDownLatch(1);
        CountDownLatch liberar = new CountDownLatch(1);
        Thread replica1 = Thread.ofVirtual().start(() -> transacao.executeWithoutResult(status -> {
            // na mesma thread: o lock vale enquanto a transacao desta "replica" estiver aberta
            await().pollInSameThread().until(() -> idsTravados().contains(messageId));
            travou.countDown();
            aguardar(liberar);
        }));
        try {
            assertThat(travou.await(15, TimeUnit.SECONDS)).isTrue();

            Set<UUID> vistosPelaReplica2 = transacao.execute(status -> idsTravados());

            assertThat(vistosPelaReplica2).doesNotContain(messageId);
        } finally {
            liberar.countDown();
            replica1.join(Duration.ofSeconds(10));
            apagar(messageId);
        }
    }

    private UUID registrarComCommit(String destino) {
        MensagemEnvelope envelope = factory.criar("TesteQuebrado", 1, Map.of());
        transacao.executeWithoutResult(status -> outbox.registrar(destino, envelope));
        return envelope.messageId();
    }

    private Set<UUID> idsTravados() {
        return repository.travarPendentes(OutboxPublisher.LOTE).stream()
                .map(OutboxEntity::getMessageId).collect(Collectors.toSet());
    }

    private Optional<OutboxEntity> buscar(UUID messageId) {
        return repository.findAll().stream().filter(m -> m.getMessageId().equals(messageId)).findFirst();
    }

    private void apagar(UUID messageId) {
        transacao.executeWithoutResult(status -> buscar(messageId).ifPresent(repository::delete));
    }

    private Message aguardarNaFilaAssinante(UUID messageId) {
        List<Message> encontrada = new java.util.concurrent.CopyOnWriteArrayList<>();
        await().until(() -> {
            receber(MENSAGERIA.filaAssinante()).stream()
                    .filter(m -> messageId.equals(messageId(m))).forEach(encontrada::add);
            return !encontrada.isEmpty();
        });
        return encontrada.getFirst();
    }

    private UUID messageId(Message mensagem) {
        try {
            return UUID.fromString(objectMapper.readTree(mensagem.body()).path("messageId").asText());
        } catch (Exception e) {
            return null;
        }
    }

    private static void aguardar(CountDownLatch latch) {
        try {
            latch.await(15, TimeUnit.SECONDS);
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
        }
    }
}
