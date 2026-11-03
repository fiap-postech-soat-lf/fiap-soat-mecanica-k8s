package br.com.fiap.soat.mecanica.servicobase.application.mensageria;

/**
 * Processa uma mensagem recebida: garante a idempotencia pelo {@code messageId} e despacha para o
 * {@link MensagemHandler} do tipo. Lancar excecao significa "nao processada" (a mensagem volta para a fila).
 */
public interface ProcessadorMensagem {

    void processar(MensagemEnvelope envelope);
}
