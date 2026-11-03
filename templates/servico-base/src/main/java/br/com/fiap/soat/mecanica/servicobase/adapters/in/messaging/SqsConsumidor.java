package br.com.fiap.soat.mecanica.servicobase.adapters.in.messaging;

import br.com.fiap.soat.mecanica.servicobase.adapters.out.messaging.DestinosMensageria;
import br.com.fiap.soat.mecanica.servicobase.application.mensageria.MensagemEnvelope;
import br.com.fiap.soat.mecanica.servicobase.application.mensageria.ProcessadorMensagem;
import br.com.fiap.soat.mecanica.servicobase.config.observability.Mdc;
import com.fasterxml.jackson.core.JsonProcessingException;
import com.fasterxml.jackson.databind.ObjectMapper;
import lombok.extern.slf4j.Slf4j;
import org.springframework.beans.factory.ObjectProvider;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.boot.autoconfigure.condition.ConditionalOnProperty;
import org.springframework.context.SmartLifecycle;
import org.springframework.stereotype.Component;
import software.amazon.awssdk.services.sqs.SqsClient;
import software.amazon.awssdk.services.sqs.model.Message;

import java.time.Duration;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;

/**
 * Poller SQS (AWS SDK v2): um laco por fila de {@code app.messaging.consumidor.filas}, cada um numa
 * virtual thread. Sucesso apaga a mensagem; excecao ou JSON invalido deixa a mensagem voltar apos o
 * visibility timeout, e depois de 5 recebimentos a fila manda para a DLQ.
 * <p>
 * So inicia se houver um bean {@link ProcessadorMensagem} (o servico DynamoDB da F1 nao tem). O bean e
 * buscado pelo {@link ObjectProvider} porque {@code @ConditionalOnBean} em componente escaneado depende
 * da ordem de registro.
 */
@Slf4j
@Component
@ConditionalOnProperty(name = "app.messaging.consumidor.enabled", havingValue = "true")
public class SqsConsumidor implements SmartLifecycle {

    static final int MAX_MENSAGENS = 10;
    static final Duration PAUSA_APOS_ERRO = Duration.ofSeconds(5);

    private final SqsClient sqs;
    private final ObjectMapper objectMapper;
    private final ProcessadorMensagem processador;
    private final List<String> filas;
    private final int esperaSegundos;
    private final int visibilidadeSegundos;
    private final List<Thread> lacos = new ArrayList<>();
    private volatile boolean rodando;

    @Autowired
    public SqsConsumidor(
            SqsClient sqs,
            ObjectMapper objectMapper,
            ObjectProvider<ProcessadorMensagem> processador,
            @Value("${app.messaging.consumidor.filas:}") List<String> filas,
            @Value("${app.messaging.consumidor.espera-segundos:20}") int esperaSegundos,
            @Value("${app.messaging.consumidor.visibilidade-segundos:30}") int visibilidadeSegundos) {
        this(sqs, objectMapper, processador.getIfAvailable(), filas, esperaSegundos, visibilidadeSegundos);
    }

    SqsConsumidor(SqsClient sqs, ObjectMapper objectMapper, ProcessadorMensagem processador,
                  List<String> filas, int esperaSegundos, int visibilidadeSegundos) {
        this.sqs = sqs;
        this.objectMapper = objectMapper;
        this.processador = processador;
        this.filas = filas.stream().filter(fila -> !fila.isBlank()).toList();
        this.esperaSegundos = esperaSegundos;
        this.visibilidadeSegundos = visibilidadeSegundos;
    }

    @Override
    public synchronized void start() {
        if (processador == null || filas.isEmpty()) {
            log.atInfo().addKeyValue("event", "consumidor_inativo")
                    .addKeyValue("filas", filas.size())
                    .addKeyValue("temProcessador", processador != null)
                    .log("Consumidor SQS nao iniciado");
            return;
        }
        rodando = true;
        for (String fila : filas) {
            lacos.add(Thread.ofVirtual()
                    .name("sqs-" + DestinosMensageria.nomeDaFila(fila))
                    .start(() -> consumir(fila)));
        }
        log.atInfo().addKeyValue("event", "consumidor_iniciado")
                .addKeyValue("filas", filas.stream().map(DestinosMensageria::nomeDaFila).toList())
                .log("Consumidor SQS iniciado");
    }

    /**
     * Para de buscar mensagens e espera o laco terminar o lote atual (o long polling acaba em ate
     * {@code espera-segundos}). So interrompe a thread se ela passar desse prazo.
     */
    @Override
    public synchronized void stop() {
        rodando = false;
        Duration prazo = Duration.ofSeconds(esperaSegundos + 5L);
        for (Thread laco : lacos) {
            try {
                if (!laco.join(prazo)) {
                    laco.interrupt();
                }
            } catch (InterruptedException e) {
                Thread.currentThread().interrupt();
                break;
            }
        }
        lacos.clear();
    }

    @Override
    public boolean isRunning() {
        return rodando;
    }

    private void consumir(String fila) {
        while (rodando) {
            List<Message> mensagens;
            try {
                mensagens = sqs.receiveMessage(r -> r.queueUrl(fila)
                        .waitTimeSeconds(esperaSegundos)
                        .maxNumberOfMessages(MAX_MENSAGENS)
                        .visibilityTimeout(visibilidadeSegundos)).messages();
            } catch (RuntimeException e) {
                if (!rodando) {
                    return;
                }
                log.atWarn().addKeyValue("event", "sqs_receive_falhou")
                        .addKeyValue("fila", DestinosMensageria.nomeDaFila(fila))
                        .addKeyValue("erro", e.getMessage())
                        .log("Falha ao buscar mensagens; nova tentativa em {}", PAUSA_APOS_ERRO);
                if (!pausar()) {
                    return;
                }
                continue;
            }
            mensagens.forEach(mensagem -> tratar(fila, mensagem));
        }
    }

    void tratar(String fila, Message mensagem) {
        MensagemEnvelope envelope;
        try {
            envelope = objectMapper.readValue(mensagem.body(), MensagemEnvelope.class);
        } catch (JsonProcessingException e) {
            log.atError().addKeyValue("event", "mensagem_falhou")
                    .addKeyValue("fila", DestinosMensageria.nomeDaFila(fila))
                    .addKeyValue("sqsMessageId", mensagem.messageId())
                    .addKeyValue("motivo", "json_invalido")
                    .log("Mensagem com JSON invalido: {}", e.getOriginalMessage());
            return;
        }

        try (var ignored = Mdc.abrir(contexto(envelope))) {
            processador.processar(envelope);
            sqs.deleteMessage(r -> r.queueUrl(fila).receiptHandle(mensagem.receiptHandle()));
            log.atDebug().addKeyValue("event", "mensagem_processada")
                    .addKeyValue("fila", DestinosMensageria.nomeDaFila(fila))
                    .addKeyValue("tipo", envelope.type())
                    .log("Mensagem processada");
        } catch (RuntimeException e) {
            log.atError().addKeyValue("event", "mensagem_falhou")
                    .addKeyValue("fila", DestinosMensageria.nomeDaFila(fila))
                    .addKeyValue("tipo", envelope.type())
                    .addKeyValue("motivo", "processamento")
                    .setCause(e)
                    .log("Falha ao processar a mensagem; ela volta para a fila");
        }
    }

    private static Map<String, Object> contexto(MensagemEnvelope envelope) {
        Map<String, Object> valores = new HashMap<>();
        valores.put(Mdc.CORRELATION_ID, envelope.correlationId());
        valores.put(Mdc.SAGA_ID, envelope.sagaId());
        valores.put(Mdc.OS_ID, envelope.osId());
        valores.put(Mdc.MESSAGE_ID, envelope.messageId());
        return valores;
    }

    private boolean pausar() {
        try {
            Thread.sleep(PAUSA_APOS_ERRO);
            return true;
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
            return false;
        }
    }
}
