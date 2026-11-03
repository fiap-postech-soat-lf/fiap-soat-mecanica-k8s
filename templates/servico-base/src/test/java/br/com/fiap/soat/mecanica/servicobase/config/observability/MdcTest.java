package br.com.fiap.soat.mecanica.servicobase.config.observability;

import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.Test;
import org.slf4j.MDC;

import java.util.HashMap;
import java.util.Map;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;

class MdcTest {

    @AfterEach
    void limpar() {
        MDC.clear();
    }

    @Test
    void abreEscopoIgnorandoNulosERestauraNoFechamento() {
        MDC.put(Mdc.SAGA_ID, "saga-anterior");
        UUID osId = UUID.randomUUID();
        Map<String, Object> valores = new HashMap<>();
        valores.put(Mdc.SAGA_ID, "saga-nova");
        valores.put(Mdc.OS_ID, osId);
        valores.put(Mdc.MESSAGE_ID, null);

        try (Mdc.Escopo ignored = Mdc.abrir(valores)) {
            assertThat(MDC.get(Mdc.SAGA_ID)).isEqualTo("saga-nova");
            assertThat(MDC.get(Mdc.OS_ID)).isEqualTo(osId.toString());
            assertThat(MDC.get(Mdc.MESSAGE_ID)).isNull();
        }

        assertThat(MDC.get(Mdc.SAGA_ID)).isEqualTo("saga-anterior");
        assertThat(MDC.get(Mdc.OS_ID)).isNull();
    }

    @Test
    void correlationIdLeDoMdc() {
        assertThat(Mdc.correlationId()).isNull();
        MDC.put(Mdc.CORRELATION_ID, "corr-1");
        assertThat(Mdc.correlationId()).isEqualTo("corr-1");
    }
}
