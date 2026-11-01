package br.com.fiap.soat.mecanica.servicobase.config.observability;

import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.Test;
import org.slf4j.MDC;
import org.springframework.http.HttpMethod;
import org.springframework.http.HttpStatus;
import org.springframework.mock.http.client.MockClientHttpRequest;
import org.springframework.mock.http.client.MockClientHttpResponse;

import java.net.URI;

import static org.assertj.core.api.Assertions.assertThat;

class CorrelationIdInterceptorTest {

    private final CorrelationIdInterceptor interceptor = new CorrelationIdInterceptor();

    @AfterEach
    void limpar() {
        MDC.clear();
    }

    @Test
    void propagaCorrelationIdDoMdc() throws Exception {
        MDC.put(Mdc.CORRELATION_ID, "corr-123");
        MockClientHttpRequest request = new MockClientHttpRequest(HttpMethod.GET, URI.create("http://identity/clientes"));

        interceptor.intercept(request, new byte[0], (req, body) -> new MockClientHttpResponse(new byte[0], HttpStatus.OK));

        assertThat(request.getHeaders().getFirst("X-Correlation-Id")).isEqualTo("corr-123");
    }

    @Test
    void semCorrelationIdNoMdcNaoAdicionaHeader() throws Exception {
        MockClientHttpRequest request = new MockClientHttpRequest(HttpMethod.GET, URI.create("http://identity/clientes"));

        interceptor.intercept(request, new byte[0], (req, body) -> new MockClientHttpResponse(new byte[0], HttpStatus.OK));

        assertThat(request.getHeaders().containsKey("X-Correlation-Id")).isFalse();
    }

    @Test
    void naoSobrescreveHeaderInformadoPeloChamador() throws Exception {
        MDC.put(Mdc.CORRELATION_ID, "corr-123");
        MockClientHttpRequest request = new MockClientHttpRequest(HttpMethod.GET, URI.create("http://identity/clientes"));
        request.getHeaders().set("X-Correlation-Id", "explicito");

        interceptor.intercept(request, new byte[0], (req, body) -> new MockClientHttpResponse(new byte[0], HttpStatus.OK));

        assertThat(request.getHeaders().getFirst("X-Correlation-Id")).isEqualTo("explicito");
    }
}
