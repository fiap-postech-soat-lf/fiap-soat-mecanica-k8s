package br.com.fiap.soat.mecanica.servicobase.application.mensageria;

/**
 * Trata um tipo de mensagem. Roda dentro da transacao do {@link ProcessadorMensagem}: escritas de
 * negocio e de outbox feitas aqui sao confirmadas junto com o registro de idempotencia.
 */
public interface MensagemHandler {

    /** Valor de {@code type} do envelope que este handler trata (ex.: {@code ReservarPecas}). */
    String tipo();

    void processar(MensagemEnvelope envelope);
}
