package br.com.fiap.soat.mecanica.servicobase.config;

import br.com.fiap.soat.mecanica.servicobase.config.observability.CorrelationIdInterceptor;
import org.springframework.boot.web.client.RestClientCustomizer;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.http.client.JdkClientHttpRequestFactory;

import java.net.http.HttpClient;
import java.time.Duration;

/**
 * Todo RestClient criado a partir do RestClient.Builder do Spring tem timeouts de 2 s e propaga o
 * X-Correlation-Id. As chamadas sincronas entre servicos (F4 e F5) usam esse builder.
 */
@Configuration
public class RestClientConfig {

    static final Duration TIMEOUT = Duration.ofSeconds(2);

    @Bean
    public RestClientCustomizer timeoutsECorrelacao() {
        return builder -> {
            HttpClient httpClient = HttpClient.newBuilder().connectTimeout(TIMEOUT).build();
            JdkClientHttpRequestFactory requestFactory = new JdkClientHttpRequestFactory(httpClient);
            requestFactory.setReadTimeout(TIMEOUT);
            builder.requestFactory(requestFactory)
                    .requestInterceptor(new CorrelationIdInterceptor());
        };
    }
}
