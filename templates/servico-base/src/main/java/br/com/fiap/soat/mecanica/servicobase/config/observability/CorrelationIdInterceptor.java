package br.com.fiap.soat.mecanica.servicobase.config.observability;

import org.springframework.http.HttpRequest;
import org.springframework.http.client.ClientHttpRequestExecution;
import org.springframework.http.client.ClientHttpRequestInterceptor;
import org.springframework.http.client.ClientHttpResponse;

import java.io.IOException;

/** Propaga o correlationId do MDC no header X-Correlation-Id de toda chamada feita pelo RestClient. */
public class CorrelationIdInterceptor implements ClientHttpRequestInterceptor {

    @Override
    public ClientHttpResponse intercept(HttpRequest request, byte[] body, ClientHttpRequestExecution execution)
            throws IOException {
        String correlationId = Mdc.correlationId();
        if (correlationId != null && !request.getHeaders().containsKey(HttpRequestLoggingFilter.CORRELATION_ID_HEADER)) {
            request.getHeaders().set(HttpRequestLoggingFilter.CORRELATION_ID_HEADER, correlationId);
        }
        return execution.execute(request, body);
    }
}
