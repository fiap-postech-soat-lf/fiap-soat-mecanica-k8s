package br.com.fiap.soat.mecanica.servicobase.support;

import br.com.fiap.soat.mecanica.servicobase.application.mensageria.MensagemEnvelope;
import br.com.fiap.soat.mecanica.servicobase.application.mensageria.MensagemHandler;
import br.com.fiap.soat.mecanica.servicobase.config.observability.Mdc;

import java.util.List;
import java.util.UUID;
import java.util.concurrent.CopyOnWriteArrayList;
import java.util.function.Consumer;

/** Handler do tipo {@value #TIPO}: registra cada chamada e executa a acao configurada pelo teste. */
public class HandlerDeTeste implements MensagemHandler {

    public static final String TIPO = "TesteRecebido";

    public record Chamada(MensagemEnvelope envelope, String correlationIdNoMdc) {
    }

    private final List<Chamada> chamadas = new CopyOnWriteArrayList<>();
    private volatile Consumer<MensagemEnvelope> acao = envelope -> { };

    @Override
    public String tipo() {
        return TIPO;
    }

    @Override
    public void processar(MensagemEnvelope envelope) {
        chamadas.add(new Chamada(envelope, Mdc.correlationId()));
        acao.accept(envelope);
    }

    public void quandoProcessar(Consumer<MensagemEnvelope> acao) {
        this.acao = acao;
    }

    public List<Chamada> chamadas(UUID messageId) {
        return chamadas.stream().filter(c -> c.envelope().messageId().equals(messageId)).toList();
    }

    public void reiniciar() {
        acao = envelope -> { };
        chamadas.clear();
    }
}
