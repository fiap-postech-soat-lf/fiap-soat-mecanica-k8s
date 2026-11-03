package br.com.fiap.soat.mecanica.servicobase.adapters.out.persistence.mensageria;

import br.com.fiap.soat.mecanica.servicobase.adapters.out.messaging.SnsSqsPublicador;
import lombok.extern.slf4j.Slf4j;
import org.springframework.scheduling.annotation.Scheduled;
import org.springframework.stereotype.Component;
import org.springframework.transaction.support.TransactionTemplate;

import java.time.Instant;
import java.util.List;

/**
 * Publica as mensagens pendentes da outbox a cada 1 s, em lotes de 50. A publicacao acontece com as
 * linhas travadas: se o pod cair entre publicar e confirmar, a mensagem e publicada de novo
 * (at-least-once; o consumidor e idempotente).
 */
@Slf4j
@Component
public class OutboxPublisher {

    static final int LOTE = 50;
    static final int TAMANHO_MAXIMO_ERRO = 1000;

    private final OutboxJpaRepository repository;
    private final SnsSqsPublicador publicador;
    private final TransactionTemplate transacao;

    public OutboxPublisher(OutboxJpaRepository repository, SnsSqsPublicador publicador, TransactionTemplate transacao) {
        this.repository = repository;
        this.publicador = publicador;
        this.transacao = transacao;
    }

    @Scheduled(fixedDelay = 1000)
    public void agendado() {
        publicarPendentes();
    }

    /** @return quantas mensagens foram publicadas nesta rodada */
    public int publicarPendentes() {
        Integer publicadas = transacao.execute(status -> {
            List<OutboxEntity> pendentes = repository.travarPendentes(LOTE);
            int ok = 0;
            for (OutboxEntity mensagem : pendentes) {
                if (publicar(mensagem)) {
                    ok++;
                }
            }
            return ok;
        });
        return publicadas == null ? 0 : publicadas;
    }

    private boolean publicar(OutboxEntity mensagem) {
        try {
            publicador.publicar(mensagem.getDestino(), mensagem.getTipo(), mensagem.getEnvelope());
            mensagem.setPublicadoEm(Instant.now());
            return true;
        } catch (RuntimeException e) {
            mensagem.setTentativas(mensagem.getTentativas() + 1);
            mensagem.setUltimoErro(truncar(e.toString()));
            log.atWarn().addKeyValue("event", "outbox_publicacao_falhou")
                    .addKeyValue("destino", mensagem.getDestino())
                    .addKeyValue("tipo", mensagem.getTipo())
                    .addKeyValue("messageId", mensagem.getMessageId())
                    .addKeyValue("tentativas", mensagem.getTentativas())
                    .log("Falha ao publicar mensagem da outbox: {}", e.getMessage());
            return false;
        }
    }

    private static String truncar(String erro) {
        return erro.length() <= TAMANHO_MAXIMO_ERRO ? erro : erro.substring(0, TAMANHO_MAXIMO_ERRO);
    }
}
