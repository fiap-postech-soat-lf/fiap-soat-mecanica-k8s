package br.com.fiap.soat.mecanica.servicobase.application.mensageria;

/**
 * Registra uma mensagem para publicacao. Deve ser chamado dentro da transacao do caso de uso:
 * a mensagem so e publicada se a transacao for confirmada.
 */
public interface OutboxPort {

    /**
     * @param destino nome logico do destino ({@code app.messaging.destinos.<nome>}), ex.: {@code execucao-comandos}
     */
    void registrar(String destino, MensagemEnvelope envelope);
}
