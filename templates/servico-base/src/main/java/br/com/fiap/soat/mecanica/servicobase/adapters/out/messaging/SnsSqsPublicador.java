package br.com.fiap.soat.mecanica.servicobase.adapters.out.messaging;

import org.springframework.stereotype.Component;
import software.amazon.awssdk.services.sns.SnsClient;
import software.amazon.awssdk.services.sqs.SqsClient;

import java.util.Map;

/**
 * Publica um envelope ja serializado no destino logico: ARN de topico vai para o SNS e URL de fila
 * vai direto para o SQS. O atributo de mensagem {@code type} acompanha os dois casos (com raw delivery
 * o SNS repassa os atributos para a fila assinada).
 */
@Component
public class SnsSqsPublicador {

    static final String ATRIBUTO_TIPO = "type";

    private final SnsClient sns;
    private final SqsClient sqs;
    private final DestinosMensageria destinos;

    public SnsSqsPublicador(SnsClient sns, SqsClient sqs, DestinosMensageria destinos) {
        this.sns = sns;
        this.sqs = sqs;
        this.destinos = destinos;
    }

    public void publicar(String destino, String tipo, String envelopeJson) {
        String endereco = destinos.resolver(destino);
        if (endereco.startsWith("arn:aws:sns:")) {
            sns.publish(r -> r.topicArn(endereco).message(envelopeJson)
                    .messageAttributes(Map.of(ATRIBUTO_TIPO, atributoSns(tipo))));
        } else if (endereco.startsWith("http://") || endereco.startsWith("https://")) {
            sqs.sendMessage(r -> r.queueUrl(endereco).messageBody(envelopeJson)
                    .messageAttributes(Map.of(ATRIBUTO_TIPO, atributoSqs(tipo))));
        } else {
            throw new IllegalStateException("Destino " + destino + " nao e ARN de topico SNS nem URL de fila SQS");
        }
    }

    private static software.amazon.awssdk.services.sns.model.MessageAttributeValue atributoSns(String tipo) {
        return software.amazon.awssdk.services.sns.model.MessageAttributeValue.builder()
                .dataType("String").stringValue(tipo).build();
    }

    private static software.amazon.awssdk.services.sqs.model.MessageAttributeValue atributoSqs(String tipo) {
        return software.amazon.awssdk.services.sqs.model.MessageAttributeValue.builder()
                .dataType("String").stringValue(tipo).build();
    }
}
