package br.com.fiap.soat.mecanica.servicobase.adapters.out.persistence.mensageria;

import br.com.fiap.soat.mecanica.servicobase.application.mensageria.MensagemEnvelope;
import br.com.fiap.soat.mecanica.servicobase.application.mensageria.MensagemHandler;
import br.com.fiap.soat.mecanica.servicobase.application.mensageria.ProcessadorMensagem;
import lombok.extern.slf4j.Slf4j;
import org.springframework.stereotype.Component;
import org.springframework.transaction.annotation.Transactional;

import java.util.List;
import java.util.Map;
import java.util.function.Function;
import java.util.stream.Collectors;

/**
 * Idempotencia pelo messageId e despacho para o handler do tipo, numa unica transacao: se o handler
 * falhar, o registro em mensagem_processada e as escritas do handler (negocio e outbox) sao desfeitos.
 */
@Slf4j
@Component
public class ProcessadorMensagemSql implements ProcessadorMensagem {

    private final MensagemProcessadaJpaRepository repository;
    private final Map<String, MensagemHandler> handlers;

    public ProcessadorMensagemSql(MensagemProcessadaJpaRepository repository, List<MensagemHandler> handlers) {
        this.repository = repository;
        this.handlers = handlers.stream().collect(Collectors.toMap(MensagemHandler::tipo, Function.identity(),
                (a, b) -> {
                    throw new IllegalStateException("Dois handlers para o tipo " + a.tipo());
                }));
    }

    @Override
    @Transactional
    public void processar(MensagemEnvelope envelope) {
        if (repository.registrarSeNova(envelope.messageId(), envelope.type()) == 0) {
            log.atInfo().addKeyValue("event", "mensagem_duplicada")
                    .addKeyValue("tipo", envelope.type())
                    .log("Mensagem ja processada; ignorada");
            return;
        }
        MensagemHandler handler = handlers.get(envelope.type());
        if (handler == null) {
            log.atInfo().addKeyValue("event", "mensagem_ignorada")
                    .addKeyValue("tipo", envelope.type())
                    .log("Tipo de mensagem sem handler neste servico");
            return;
        }
        handler.processar(envelope);
    }
}
