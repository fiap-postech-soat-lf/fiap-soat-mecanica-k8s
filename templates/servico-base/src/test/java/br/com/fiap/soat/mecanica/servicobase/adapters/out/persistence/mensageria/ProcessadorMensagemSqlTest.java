package br.com.fiap.soat.mecanica.servicobase.adapters.out.persistence.mensageria;

import br.com.fiap.soat.mecanica.servicobase.application.mensageria.MensagemEnvelope;
import br.com.fiap.soat.mecanica.servicobase.application.mensageria.MensagemHandler;
import org.junit.jupiter.api.Test;

import java.util.List;

import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.Mockito.mock;

class ProcessadorMensagemSqlTest {

    @Test
    void doisHandlersParaOMesmoTipoImpedemASubida() {
        List<MensagemHandler> handlers = List.of(handler("ReservarPecas"), handler("ReservarPecas"));
        MensagemProcessadaJpaRepository repository = mock(MensagemProcessadaJpaRepository.class);

        assertThatThrownBy(() -> new ProcessadorMensagemSql(repository, handlers))
                .isInstanceOf(IllegalStateException.class)
                .hasMessageContaining("ReservarPecas");
    }

    private static MensagemHandler handler(String tipo) {
        return new MensagemHandler() {
            @Override
            public String tipo() {
                return tipo;
            }

            @Override
            public void processar(MensagemEnvelope envelope) {
                // sem efeito
            }
        };
    }
}
