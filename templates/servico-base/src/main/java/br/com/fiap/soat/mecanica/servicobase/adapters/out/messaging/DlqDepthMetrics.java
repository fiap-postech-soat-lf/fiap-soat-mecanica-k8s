package br.com.fiap.soat.mecanica.servicobase.adapters.out.messaging;

import io.micrometer.core.instrument.Gauge;
import io.micrometer.core.instrument.MeterRegistry;
import lombok.extern.slf4j.Slf4j;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.scheduling.annotation.Scheduled;
import org.springframework.stereotype.Component;
import software.amazon.awssdk.core.exception.SdkException;
import software.amazon.awssdk.services.sqs.SqsClient;
import software.amazon.awssdk.services.sqs.model.QueueAttributeName;

import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.concurrent.atomic.AtomicLong;

/**
 * Gauge {@code dlq.depth{fila}} com a quantidade de mensagens em cada DLQ de {@code app.messaging.dlqs}.
 * Atualizado a cada 60 s; se a leitura falhar, mantem o ultimo valor.
 */
@Slf4j
@Component
public class DlqDepthMetrics {

    static final String METRICA = "dlq.depth";

    private final SqsClient sqs;
    private final Map<String, AtomicLong> profundidades = new LinkedHashMap<>();

    public DlqDepthMetrics(SqsClient sqs, MeterRegistry registry, @Value("${app.messaging.dlqs:}") List<String> dlqs) {
        this.sqs = sqs;
        dlqs.stream().filter(url -> !url.isBlank()).forEach(url -> {
            AtomicLong profundidade = new AtomicLong();
            profundidades.put(url, profundidade);
            Gauge.builder(METRICA, profundidade, AtomicLong::get)
                    .tag("fila", DestinosMensageria.nomeDaFila(url))
                    .description("Mensagens na DLQ")
                    .register(registry);
        });
    }

    @Scheduled(fixedDelay = 60_000)
    public void atualizar() {
        profundidades.forEach((url, profundidade) -> {
            try {
                String valor = sqs.getQueueAttributes(r -> r.queueUrl(url)
                                .attributeNames(QueueAttributeName.APPROXIMATE_NUMBER_OF_MESSAGES))
                        .attributes().get(QueueAttributeName.APPROXIMATE_NUMBER_OF_MESSAGES);
                profundidade.set(Long.parseLong(valor));
            } catch (SdkException | NumberFormatException e) {
                log.atWarn().addKeyValue("event", "dlq_depth_falhou")
                        .addKeyValue("fila", DestinosMensageria.nomeDaFila(url))
                        .addKeyValue("erro", e.getMessage())
                        .log("Nao foi possivel ler a profundidade da DLQ");
            }
        });
    }
}
