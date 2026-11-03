package br.com.fiap.soat.mecanica.servicobase.config;

import br.com.fiap.soat.mecanica.servicobase.config.observability.Mdc;
import com.sun.net.httpserver.HttpServer;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.slf4j.MDC;
import org.springframework.web.client.ResourceAccessException;
import org.springframework.web.client.RestClient;

import java.io.IOException;
import java.net.InetSocketAddress;
import java.util.concurrent.atomic.AtomicReference;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

class RestClientConfigTest {

    private HttpServer servidor;
    private final AtomicReference<String> headerRecebido = new AtomicReference<>();

    @BeforeEach
    void subirServidor() throws IOException {
        servidor = HttpServer.create(new InetSocketAddress("127.0.0.1", 0), 0);
        servidor.createContext("/ok", troca -> {
            headerRecebido.set(troca.getRequestHeaders().getFirst("X-Correlation-Id"));
            troca.sendResponseHeaders(204, -1);
            troca.close();
        });
        servidor.createContext("/lento", troca -> {
            try {
                Thread.sleep(RestClientConfig.TIMEOUT.toMillis() + 1500);
            } catch (InterruptedException e) {
                Thread.currentThread().interrupt();
            }
            troca.sendResponseHeaders(204, -1);
            troca.close();
        });
        servidor.start();
    }

    @AfterEach
    void derrubarServidor() {
        servidor.stop(0);
        MDC.clear();
    }

    @Test
    void restClientPropagaCorrelationId() {
        MDC.put(Mdc.CORRELATION_ID, "corr-rest");

        cliente().get().uri("/ok").retrieve().toBodilessEntity();

        assertThat(headerRecebido).hasValue("corr-rest");
    }

    @Test
    void restClientRespeitaTimeoutDeLeitura() {
        assertThatThrownBy(() -> cliente().get().uri("/lento").retrieve().toBodilessEntity())
                .isInstanceOf(ResourceAccessException.class);
    }

    private RestClient cliente() {
        RestClient.Builder builder = RestClient.builder()
                .baseUrl("http://127.0.0.1:" + servidor.getAddress().getPort());
        new RestClientConfig().timeoutsECorrelacao().customize(builder);
        return builder.build();
    }
}
