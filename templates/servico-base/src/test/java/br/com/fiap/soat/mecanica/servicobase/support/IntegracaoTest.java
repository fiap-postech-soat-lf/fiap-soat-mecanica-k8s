package br.com.fiap.soat.mecanica.servicobase.support;

import org.springframework.boot.test.autoconfigure.web.servlet.AutoConfigureMockMvc;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.context.annotation.Import;
import org.springframework.test.context.ActiveProfiles;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.springframework.test.context.DynamicPropertySource;
import org.testcontainers.containers.localstack.LocalStackContainer;
import org.testcontainers.containers.localstack.LocalStackContainer.Service;
// [SQL]
import org.testcontainers.containers.PostgreSQLContainer;
// [/SQL]
import org.testcontainers.utility.DockerImageName;
import software.amazon.awssdk.auth.credentials.AwsBasicCredentials;
import software.amazon.awssdk.auth.credentials.StaticCredentialsProvider;
import software.amazon.awssdk.awscore.client.builder.AwsClientBuilder;
import software.amazon.awssdk.regions.Region;
import software.amazon.awssdk.services.sns.SnsClient;
import software.amazon.awssdk.services.sqs.SqsClient;
import software.amazon.awssdk.services.sqs.model.Message;
import software.amazon.awssdk.services.sqs.model.QueueAttributeName;

import java.util.List;
import java.util.Map;
import java.util.UUID;

/**
 * Base dos testes de integracao. Os containers sao estaticos e iniciados uma vez por JVM
 * (reaproveitados por todas as classes de teste), para o build ficar abaixo de ~3 min.
 * <p>
 * Todas as subclasses compartilham <b>um</b> contexto Spring: nao declare {@code @SpringBootTest},
 * {@code @Import}, {@code @TestPropertySource} ou {@code @MockitoBean} nelas. Com dois contextos em cache,
 * o consumidor e o OutboxPublisher de um roubariam mensagens e linhas da outbox do outro.
 * Componentes de teste vao em {@link ComponentesDeTeste}.
 */
@SpringBootTest
@AutoConfigureMockMvc
@ActiveProfiles("test")
@Import(ComponentesDeTeste.class)
public abstract class IntegracaoTest {

    // [SQL]
    static final PostgreSQLContainer<?> POSTGRES =
            new PostgreSQLContainer<>(DockerImageName.parse("postgres:17-alpine"))
                    .withDatabaseName("servicobase_test")
                    .withUsername("postgres")
                    .withPassword("postgres");
    // [/SQL]

    /** Ultima tag 4.x (edicao community, sem LOCALSTACK_AUTH_TOKEN). */
    static final LocalStackContainer LOCALSTACK =
            new LocalStackContainer(DockerImageName.parse("localstack/localstack:4.14.0"))
                    .withServices(Service.SNS, Service.SQS);

    protected static final SqsClient SQS;
    protected static final SnsClient SNS;
    protected static final Mensageria MENSAGERIA;

    static {
        // [SQL]
        POSTGRES.start();
        // [/SQL]
        LOCALSTACK.start();
        SQS = configurar(SqsClient.builder()).build();
        SNS = configurar(SnsClient.builder()).build();
        MENSAGERIA = Mensageria.criar();
    }

    @DynamicPropertySource
    static void registrarPropriedades(DynamicPropertyRegistry registry) {
        registry.add("app.security.jwt.public-key", JwtTestTokens::chavePublicaPem);
        registry.add("app.aws.endpoint", () -> LOCALSTACK.getEndpoint().toString());
        registry.add("app.aws.region", LOCALSTACK::getRegion);
        registry.add("app.aws.access-key-id", LOCALSTACK::getAccessKey);
        registry.add("app.aws.secret-access-key", LOCALSTACK::getSecretKey);
        registry.add("app.messaging.consumidor.enabled", () -> "true");
        registry.add("app.messaging.consumidor.filas", MENSAGERIA::filaEntrada);
        registry.add("app.messaging.consumidor.espera-segundos", () -> "1");
        // Mensagem que falhou volta em 2 s (e nao em 30 s), para nao segurar a fila entre um teste e outro
        registry.add("app.messaging.consumidor.visibilidade-segundos", () -> "2");
        registry.add("app.messaging.dlqs", MENSAGERIA::dlq);
        registry.add("app.messaging.destinos.teste-eventos", MENSAGERIA::topicoEventos);
        registry.add("app.messaging.destinos.teste-comandos", MENSAGERIA::filaComandos);
        registry.add("app.messaging.destinos.teste-quebrado", MENSAGERIA::topicoInexistente);
        // [SQL]
        registry.add("spring.datasource.url", POSTGRES::getJdbcUrl);
        registry.add("spring.datasource.username", POSTGRES::getUsername);
        registry.add("spring.datasource.password", POSTGRES::getPassword);
        // [/SQL]
    }

    /** Fila criada na hora, para testes que precisam de uma fila so deles. */
    protected static String criarFila(String prefixo) {
        return SQS.createQueue(r -> r.queueName("servicobase-teste-" + prefixo + "-" + UUID.randomUUID()))
                .queueUrl();
    }

    /** Mensagens visiveis + em voo (recebidas e ainda nao apagadas). */
    protected static int mensagensNaFila(String url) {
        Map<QueueAttributeName, String> atributos = SQS.getQueueAttributes(r -> r.queueUrl(url).attributeNames(
                QueueAttributeName.APPROXIMATE_NUMBER_OF_MESSAGES,
                QueueAttributeName.APPROXIMATE_NUMBER_OF_MESSAGES_NOT_VISIBLE)).attributes();
        return Integer.parseInt(atributos.get(QueueAttributeName.APPROXIMATE_NUMBER_OF_MESSAGES))
                + Integer.parseInt(atributos.get(QueueAttributeName.APPROXIMATE_NUMBER_OF_MESSAGES_NOT_VISIBLE));
    }

    /** Mensagens recebidas e ainda nao apagadas (esperando o visibility timeout). */
    protected static int mensagensEmVoo(String url) {
        return Integer.parseInt(SQS.getQueueAttributes(r -> r.queueUrl(url)
                        .attributeNames(QueueAttributeName.APPROXIMATE_NUMBER_OF_MESSAGES_NOT_VISIBLE))
                .attributes().get(QueueAttributeName.APPROXIMATE_NUMBER_OF_MESSAGES_NOT_VISIBLE));
    }

    /** Recebe (e apaga) as mensagens disponiveis na fila, com os atributos de mensagem. */
    protected static List<Message> receber(String url) {
        List<Message> mensagens = SQS.receiveMessage(r -> r.queueUrl(url)
                .maxNumberOfMessages(10).waitTimeSeconds(1).messageAttributeNames("All")).messages();
        mensagens.forEach(m -> SQS.deleteMessage(r -> r.queueUrl(url).receiptHandle(m.receiptHandle())));
        return mensagens;
    }

    private static <B extends AwsClientBuilder<B, ?>> B configurar(B builder) {
        return builder.endpointOverride(LOCALSTACK.getEndpoint())
                .region(Region.of(LOCALSTACK.getRegion()))
                .credentialsProvider(StaticCredentialsProvider.create(
                        AwsBasicCredentials.create(LOCALSTACK.getAccessKey(), LOCALSTACK.getSecretKey())));
    }

    /**
     * Recursos de mensageria do contexto compartilhado. {@code filaEntrada} e consumida pelo SqsConsumidor
     * da aplicacao; {@code filaAssinante} recebe (raw) o que e publicado em {@code topicoEventos}.
     */
    public record Mensageria(String filaEntrada, String topicoEventos, String filaAssinante,
                             String filaComandos, String dlq, String topicoInexistente) {

        static Mensageria criar() {
            String filaEntrada = SQS.createQueue(r -> r.queueName("servicobase-teste-entrada")).queueUrl();
            String filaAssinante = SQS.createQueue(r -> r.queueName("servicobase-teste-assinante")).queueUrl();
            String filaComandos = SQS.createQueue(r -> r.queueName("servicobase-teste-comandos")).queueUrl();
            String dlq = SQS.createQueue(r -> r.queueName("servicobase-teste-dlq")).queueUrl();
            String topico = SNS.createTopic(r -> r.name("servicobase-teste-eventos")).topicArn();
            String arnAssinante = SQS.getQueueAttributes(r -> r.queueUrl(filaAssinante)
                    .attributeNames(QueueAttributeName.QUEUE_ARN)).attributes().get(QueueAttributeName.QUEUE_ARN);
            SNS.subscribe(r -> r.topicArn(topico).protocol("sqs").endpoint(arnAssinante)
                    .attributes(Map.of("RawMessageDelivery", "true")));
            String inexistente = topico.substring(0, topico.lastIndexOf(':') + 1) + "servicobase-teste-inexistente";
            return new Mensageria(filaEntrada, topico, filaAssinante, filaComandos, dlq, inexistente);
        }
    }
}
