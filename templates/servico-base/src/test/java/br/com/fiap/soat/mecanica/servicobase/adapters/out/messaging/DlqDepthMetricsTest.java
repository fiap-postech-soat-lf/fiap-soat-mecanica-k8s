package br.com.fiap.soat.mecanica.servicobase.adapters.out.messaging;

import io.micrometer.core.instrument.simple.SimpleMeterRegistry;
import org.junit.jupiter.api.Test;
import software.amazon.awssdk.services.sqs.SqsClient;
import software.amazon.awssdk.services.sqs.model.GetQueueAttributesRequest;
import software.amazon.awssdk.services.sqs.model.GetQueueAttributesResponse;
import software.amazon.awssdk.services.sqs.model.QueueAttributeName;
import software.amazon.awssdk.services.sqs.model.SqsException;

import java.util.List;
import java.util.Map;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.Mockito.CALLS_REAL_METHODS;
import static org.mockito.Mockito.doReturn;
import static org.mockito.Mockito.doThrow;
import static org.mockito.Mockito.mock;

class DlqDepthMetricsTest {

    private static final String DLQ = "http://localhost:4566/000000000000/mecanica-os-saga-respostas-dlq";

    // Os metodos com Consumer<Builder> sao default no cliente do SDK; CALLS_REAL_METHODS os faz chegar no stub
    private final SqsClient sqs = mock(SqsClient.class, CALLS_REAL_METHODS);
    private final SimpleMeterRegistry registry = new SimpleMeterRegistry();

    @Test
    void erroDeAwsMantemOUltimoValor() {
        DlqDepthMetrics metrics = new DlqDepthMetrics(sqs, registry, List.of(DLQ));
        doReturn(GetQueueAttributesResponse.builder()
                .attributes(Map.of(QueueAttributeName.APPROXIMATE_NUMBER_OF_MESSAGES, "4")).build())
                .when(sqs).getQueueAttributes(any(GetQueueAttributesRequest.class));
        metrics.atualizar();

        doThrow(SqsException.builder().message("ExpiredToken").build())
                .when(sqs).getQueueAttributes(any(GetQueueAttributesRequest.class));
        metrics.atualizar();

        assertThat(registry.get(DlqDepthMetrics.METRICA).tag("fila", "mecanica-os-saga-respostas-dlq").gauge().value())
                .isEqualTo(4.0);
    }

    @Test
    void semDlqsConfiguradasNaoRegistraGauge() {
        new DlqDepthMetrics(sqs, registry, List.of("")).atualizar();

        assertThat(registry.find(DlqDepthMetrics.METRICA).gauges()).isEmpty();
    }
}
