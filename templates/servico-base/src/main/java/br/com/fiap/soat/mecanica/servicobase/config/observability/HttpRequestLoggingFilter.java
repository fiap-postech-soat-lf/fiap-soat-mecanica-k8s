package br.com.fiap.soat.mecanica.servicobase.config.observability;

import jakarta.servlet.FilterChain;
import jakarta.servlet.ServletException;
import jakarta.servlet.http.HttpServletRequest;
import jakarta.servlet.http.HttpServletResponse;
import lombok.extern.slf4j.Slf4j;
import org.springframework.core.Ordered;
import org.springframework.core.annotation.Order;
import org.springframework.stereotype.Component;
import org.springframework.web.filter.OncePerRequestFilter;
import org.springframework.web.servlet.HandlerMapping;

import java.io.IOException;
import java.util.Map;
import java.util.UUID;
import java.util.concurrent.TimeUnit;

@Slf4j
@Component
@Order(Ordered.HIGHEST_PRECEDENCE)
public class HttpRequestLoggingFilter extends OncePerRequestFilter {

    public static final String CORRELATION_ID_HEADER = "X-Correlation-Id";
    public static final String REQUEST_ID_HEADER = "X-Request-Id";
    private static final String FORMATO_VALIDO = "[A-Za-z0-9._-]{1,100}";
    private static final String UUID_PATH_SEGMENT =
            "(?i)(?<=/)[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}(?=/|$)";
    private static final String NUMERIC_PATH_SEGMENT = "(?<=/)\\d+(?=/|$)";

    @Override
    protected void doFilterInternal(HttpServletRequest request, HttpServletResponse response, FilterChain filterChain)
            throws ServletException, IOException {
        String correlationId = resolverCorrelationId(request);
        long start = System.nanoTime();

        try (Mdc.Escopo ignored = Mdc.abrir(Map.of(
                Mdc.CORRELATION_ID, correlationId,
                Mdc.REQUEST_ID, correlationId))) {
            response.setHeader(CORRELATION_ID_HEADER, correlationId);
            response.setHeader(REQUEST_ID_HEADER, correlationId);
            try {
                filterChain.doFilter(request, response);
            } finally {
                if (!isHealthCheck(request)) {
                    long durationMs = TimeUnit.NANOSECONDS.toMillis(System.nanoTime() - start);
                    log.atInfo()
                            .addKeyValue("event", "http_request_completed")
                            .addKeyValue("method", request.getMethod())
                            .addKeyValue("route", normalizedRoute(request))
                            .addKeyValue("status", response.getStatus())
                            .addKeyValue("durationMs", durationMs)
                            .log("HTTP request completed");
                }
            }
        }
    }

    /** Precedencia: X-Correlation-Id valido, depois X-Request-Id valido (compatibilidade), depois UUID novo. */
    String resolverCorrelationId(HttpServletRequest request) {
        for (String header : new String[] {CORRELATION_ID_HEADER, REQUEST_ID_HEADER}) {
            String valor = request.getHeader(header);
            if (valor != null && valor.matches(FORMATO_VALIDO)) {
                return valor;
            }
        }
        return UUID.randomUUID().toString();
    }

    String normalizedRoute(HttpServletRequest request) {
        Object routePattern = request.getAttribute(HandlerMapping.BEST_MATCHING_PATTERN_ATTRIBUTE);
        if (routePattern != null) {
            return routePattern.toString();
        }

        return request.getRequestURI()
                .replaceAll(UUID_PATH_SEGMENT, "{id}")
                .replaceAll(NUMERIC_PATH_SEGMENT, "{id}");
    }

    private boolean isHealthCheck(HttpServletRequest request) {
        return request.getRequestURI().startsWith("/actuator/health");
    }
}
