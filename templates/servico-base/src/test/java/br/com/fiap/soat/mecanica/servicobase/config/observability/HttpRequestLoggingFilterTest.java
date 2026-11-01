package br.com.fiap.soat.mecanica.servicobase.config.observability;

import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.Test;
import org.slf4j.MDC;
import org.springframework.mock.web.MockHttpServletRequest;
import org.springframework.mock.web.MockHttpServletResponse;
import org.springframework.web.servlet.HandlerMapping;

import java.util.concurrent.atomic.AtomicReference;

import static br.com.fiap.soat.mecanica.servicobase.config.observability.HttpRequestLoggingFilter.CORRELATION_ID_HEADER;
import static br.com.fiap.soat.mecanica.servicobase.config.observability.HttpRequestLoggingFilter.REQUEST_ID_HEADER;
import static org.assertj.core.api.Assertions.assertThat;

class HttpRequestLoggingFilterTest {

    private final HttpRequestLoggingFilter filter = new HttpRequestLoggingFilter();

    @AfterEach
    void limparMdc() {
        MDC.clear();
    }

    @Test
    void correlationIdTemPrecedenciaSobreRequestId() throws Exception {
        MockHttpServletRequest request = new MockHttpServletRequest("GET", "/ordem-servicos/1");
        request.addHeader(CORRELATION_ID_HEADER, "corr-123");
        request.addHeader(REQUEST_ID_HEADER, "req-456");
        MockHttpServletResponse response = new MockHttpServletResponse();
        AtomicReference<String> correlationNoFluxo = new AtomicReference<>();
        AtomicReference<String> requestNoFluxo = new AtomicReference<>();

        filter.doFilterInternal(request, response, (req, res) -> {
            correlationNoFluxo.set(MDC.get(Mdc.CORRELATION_ID));
            requestNoFluxo.set(MDC.get(Mdc.REQUEST_ID));
        });

        assertThat(correlationNoFluxo).hasValue("corr-123");
        assertThat(requestNoFluxo).hasValue("corr-123");
        assertThat(response.getHeader(CORRELATION_ID_HEADER)).isEqualTo("corr-123");
        assertThat(response.getHeader(REQUEST_ID_HEADER)).isEqualTo("corr-123");
    }

    @Test
    void usaRequestIdQuandoNaoHaCorrelationId() {
        MockHttpServletRequest request = new MockHttpServletRequest("GET", "/x");
        request.addHeader(REQUEST_ID_HEADER, "req-456");

        assertThat(filter.resolverCorrelationId(request)).isEqualTo("req-456");
    }

    @Test
    void formatoInvalidoEhDescartadoEGeraUuid() {
        MockHttpServletRequest request = new MockHttpServletRequest("GET", "/x");
        request.addHeader(CORRELATION_ID_HEADER, "valor com espacos\nindevido");
        request.addHeader(REQUEST_ID_HEADER, "tambem invalido!");

        assertThat(filter.resolverCorrelationId(request))
                .matches("[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}");
    }

    @Test
    void mdcEhLimpoAoFimEValorAnteriorEhRestaurado() throws Exception {
        MDC.put(Mdc.CORRELATION_ID, "anterior");
        MockHttpServletRequest request = new MockHttpServletRequest("GET", "/actuator/health");
        request.addHeader(CORRELATION_ID_HEADER, "corr-123");

        filter.doFilterInternal(request, new MockHttpServletResponse(), (req, res) -> { });

        assertThat(MDC.get(Mdc.CORRELATION_ID)).isEqualTo("anterior");
        assertThat(MDC.get(Mdc.REQUEST_ID)).isNull();
    }

    @Test
    void sanitizaIdentificadoresQuandoRotaAindaNaoFoiResolvida() {
        MockHttpServletRequest request = new MockHttpServletRequest(
                "GET", "/pecas/55555555-5555-4555-8555-555555555555/itens/123");

        assertThat(filter.normalizedRoute(request)).isEqualTo("/pecas/{id}/itens/{id}");
    }

    @Test
    void prefereTemplateResolvidoPeloSpring() {
        MockHttpServletRequest request = new MockHttpServletRequest(
                "GET", "/pecas/55555555-5555-4555-8555-555555555555");
        request.setAttribute(HandlerMapping.BEST_MATCHING_PATTERN_ATTRIBUTE, "/pecas/{pecaId}");

        assertThat(filter.normalizedRoute(request)).isEqualTo("/pecas/{pecaId}");
    }
}
