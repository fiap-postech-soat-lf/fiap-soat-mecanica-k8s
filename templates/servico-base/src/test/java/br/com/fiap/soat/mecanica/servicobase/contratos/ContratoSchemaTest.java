package br.com.fiap.soat.mecanica.servicobase.contratos;

import br.com.fiap.soat.mecanica.servicobase.application.mensageria.MensagemEnvelope;
import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.databind.node.ObjectNode;
import com.networknt.schema.Error;
import com.networknt.schema.InputFormat;
import com.networknt.schema.Schema;
import com.networknt.schema.SchemaLocation;
import com.networknt.schema.SchemaRegistry;
import com.networknt.schema.SchemaRegistryConfig;
import com.networknt.schema.SpecificationVersion;
import org.junit.jupiter.api.DynamicTest;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.TestFactory;
import org.springframework.core.io.Resource;
import org.springframework.core.io.support.PathMatchingResourcePatternResolver;
import org.springframework.http.converter.json.Jackson2ObjectMapperBuilder;

import java.io.IOException;
import java.io.UncheckedIOException;
import java.nio.charset.StandardCharsets;
import java.time.Instant;
import java.util.Arrays;
import java.util.List;
import java.util.UUID;
import java.util.regex.Matcher;
import java.util.regex.Pattern;
import java.util.stream.Stream;

import static org.assertj.core.api.Assertions.assertThat;

/**
 * Contratos de docs/contratos (no classpath de teste como contratos/):
 * <ul>
 *   <li>todo {@code *.schema.json} e um JSON Schema 2020-12 valido;</li>
 *   <li>todo {@code exemplos/<Tipo>.v<N>.json} valida contra o envelope, tem {@code type}/{@code version} iguais
 *       ao nome do arquivo e o payload valida contra {@code <Tipo>.v<N>.schema.json};</li>
 *   <li>o envelope que o servico serializa respeita o contrato.</li>
 * </ul>
 */
class ContratoSchemaTest {

    private static final Pattern EXEMPLO = Pattern.compile("(?<tipo>[A-Za-z0-9]+)\\.v(?<versao>\\d+)\\.json");
    private static final String META_SCHEMA = "https://json-schema.org/draft/2020-12/schema";

    private static final SchemaRegistry REGISTRY = SchemaRegistry.withDefaultDialect(SpecificationVersion.DRAFT_2020_12,
            builder -> builder.schemaRegistryConfig(SchemaRegistryConfig.builder().formatAssertionsEnabled(true).build()));
    private static final PathMatchingResourcePatternResolver RESOLVER = new PathMatchingResourcePatternResolver();

    private final ObjectMapper objectMapper = Jackson2ObjectMapperBuilder.json().build();
    private final Schema envelope = REGISTRY.getSchema(ler(recurso("contratos/envelope.schema.json")), InputFormat.JSON);

    @TestFactory
    Stream<DynamicTest> todoSchemaEValidoNo2020_12() {
        Schema metaSchema = REGISTRY.getSchema(SchemaLocation.of(META_SCHEMA));
        return recursos("classpath*:contratos/*.schema.json").map(schema -> DynamicTest.dynamicTest(
                schema.getFilename(), () -> {
                    String conteudo = ler(schema);
                    assertThat(objectMapper.readTree(conteudo).path("$schema").asText()).isEqualTo(META_SCHEMA);
                    assertThat(metaSchema.validate(conteudo, InputFormat.JSON)).isEmpty();
                }));
    }

    @TestFactory
    Stream<DynamicTest> todoExemploValidaContraEnvelopeEPayload() {
        return recursos("classpath*:contratos/exemplos/*.json").map(exemplo -> DynamicTest.dynamicTest(
                exemplo.getFilename(), () -> {
                    Matcher nome = EXEMPLO.matcher(exemplo.getFilename());
                    assertThat(nome.matches()).as("nome no formato <Tipo>.v<N>.json").isTrue();
                    String conteudo = ler(exemplo);
                    JsonNode json = objectMapper.readTree(conteudo);

                    assertThat(envelope.validate(conteudo, InputFormat.JSON)).isEmpty();
                    assertThat(json.path("type").asText()).isEqualTo(nome.group("tipo"));
                    assertThat(json.path("version").asInt()).isEqualTo(Integer.parseInt(nome.group("versao")));

                    String payloadSchema = "contratos/" + nome.group("tipo") + ".v" + nome.group("versao") + ".schema.json";
                    Schema payload = REGISTRY.getSchema(ler(recurso(payloadSchema)), InputFormat.JSON);
                    assertThat(payload.validate(json.path("payload").toString(), InputFormat.JSON)).isEmpty();
                }));
    }

    @Test
    void envelopeCompletoSerializadoPeloServicoRespeitaOContrato() throws Exception {
        MensagemEnvelope completo = new MensagemEnvelope(UUID.randomUUID(), "ReservarPecas", 1, UUID.randomUUID(),
                UUID.randomUUID(), "corr-123", UUID.randomUUID(), Instant.now(),
                "00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01",
                objectMapper.createObjectNode().put("osId", UUID.randomUUID().toString()));

        assertThat(validarEnvelope(objectMapper.writeValueAsString(completo))).isEmpty();
    }

    @Test
    void envelopeSemOsOpcionaisRespeitaOContrato() throws Exception {
        MensagemEnvelope minimo = new MensagemEnvelope(UUID.randomUUID(), "AbrirDiagnostico", 1, null, null,
                "corr-123", null, Instant.now(), null, objectMapper.createObjectNode());

        String json = objectMapper.writeValueAsString(minimo);

        assertThat(objectMapper.readTree(json).has("sagaId")).isFalse();
        assertThat(validarEnvelope(json)).isEmpty();
    }

    @Test
    void envelopeComCampoDesconhecidoOuSemObrigatorioEInvalido() throws Exception {
        ObjectNode valido = objectMapper.valueToTree(new MensagemEnvelope(UUID.randomUUID(), "X", 1, null, null,
                "corr-123", null, Instant.now(), null, objectMapper.createObjectNode()));

        assertThat(validarEnvelope(valido.deepCopy().put("extra", 1).toString())).isNotEmpty();
        ObjectNode semCorrelation = valido.deepCopy();
        semCorrelation.remove("correlationId");
        assertThat(validarEnvelope(semCorrelation.toString())).isNotEmpty();
        assertThat(validarEnvelope(valido.deepCopy().put("messageId", "nao-e-uuid").toString())).isNotEmpty();
        assertThat(validarEnvelope(valido.deepCopy().put("traceparent", "invalido").toString())).isNotEmpty();
    }

    private List<Error> validarEnvelope(String json) {
        return envelope.validate(json, InputFormat.JSON);
    }

    private static Stream<Resource> recursos(String padrao) {
        try {
            return Arrays.stream(RESOLVER.getResources(padrao));
        } catch (IOException e) {
            return Stream.empty();
        }
    }

    private static Resource recurso(String caminho) {
        Resource recurso = RESOLVER.getResource("classpath:" + caminho);
        assertThat(recurso.exists()).as(caminho + " no classpath de teste").isTrue();
        return recurso;
    }

    private static String ler(Resource recurso) {
        try {
            return recurso.getContentAsString(StandardCharsets.UTF_8);
        } catch (IOException e) {
            throw new UncheckedIOException(e);
        }
    }
}
