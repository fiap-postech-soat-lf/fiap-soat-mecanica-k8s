package br.com.fiap.soat.mecanica.servicobase.config.exception;

import br.com.fiap.soat.mecanica.servicobase.domain.exception.RecursoNaoEncontradoException;
import br.com.fiap.soat.mecanica.servicobase.domain.exception.RegraNegocioException;
import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;
import org.slf4j.MDC;
// [SQL]
import org.springframework.dao.DataIntegrityViolationException;
// [/SQL]
import org.springframework.http.HttpStatus;
import org.springframework.http.ResponseEntity;
import org.springframework.security.authorization.AuthorizationDeniedException;
import org.springframework.validation.BindingResult;
import org.springframework.validation.FieldError;
import org.springframework.web.bind.MethodArgumentNotValidException;

import java.util.List;
import com.fasterxml.jackson.databind.exc.InvalidFormatException;
import jakarta.validation.ConstraintViolation;
import jakarta.validation.ConstraintViolationException;
import jakarta.validation.Path;
import org.springframework.core.MethodParameter;
import org.springframework.http.HttpMethod;
import org.springframework.http.converter.HttpMessageNotReadableException;
import org.springframework.mock.http.MockHttpInputMessage;
import org.springframework.security.access.AccessDeniedException;
import org.springframework.web.HttpRequestMethodNotSupportedException;
import org.springframework.web.method.annotation.MethodArgumentTypeMismatchException;
import org.springframework.web.servlet.resource.NoResourceFoundException;
import java.util.Set;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;

class GlobalExceptionHandlerTest {

    private final GlobalExceptionHandler handler = new GlobalExceptionHandler();

    @Test
    @DisplayName("Deve incluir o identificador da requisição na resposta de erro")
    void deveIncluirErrorId() {
        MDC.put("correlationId", "request-123");
        try {
            ResponseEntity<ErrorResponse> response = handler.handleGeneric(new Exception("Erro inesperado"));

            assertThat(response.getBody().errorId()).isEqualTo("request-123");
        } finally {
            MDC.remove("correlationId");
        }
    }

    @Test
    @DisplayName("Deve retornar 422 para RegraNegocioException")
    void deveRetornar422_quandoRegraNegocio() {
        // Act
        ResponseEntity<ErrorResponse> response = handler.handleRegraNegocio(
                new RegraNegocioException("Erro de regra"));

        // Assert
        assertThat(response.getStatusCode().value()).isEqualTo(422);
        assertThat(response.getBody().mensagem()).isEqualTo("Erro de regra");
    }

    @Test
    @DisplayName("Deve retornar 404 para RecursoNaoEncontradoException")
    void deveRetornar404_quandoRecursoNaoEncontrado() {
        // Act
        ResponseEntity<ErrorResponse> response = handler.handleNotFound(
                new RecursoNaoEncontradoException("Não encontrado"));

        // Assert
        assertThat(response.getStatusCode()).isEqualTo(HttpStatus.NOT_FOUND);
    }


    @Test
    @DisplayName("Deve retornar 400 para MethodArgumentNotValidException")
    void deveRetornar400_quandoValidacaoFalha() {
        // Arrange
        BindingResult bindingResult = mock(BindingResult.class);
        FieldError fieldError = new FieldError("obj", "campo", "é obrigatório");
        when(bindingResult.getFieldErrors()).thenReturn(List.of(fieldError));
        MethodArgumentNotValidException ex = mock(MethodArgumentNotValidException.class);
        when(ex.getBindingResult()).thenReturn(bindingResult);

        // Act
        ResponseEntity<ErrorResponse> response = handler.handleValidation(ex);

        // Assert
        assertThat(response.getStatusCode()).isEqualTo(HttpStatus.BAD_REQUEST);
    }

    // [SQL]
    @Test
    @DisplayName("Deve retornar 400 para DataIntegrityViolationException")
    void deveRetornar400_quandoIntegridadeDados() {
        // Act
        ResponseEntity<ErrorResponse> response = handler.handleDataIntegrity(
                new DataIntegrityViolationException("Violation"));

        // Assert
        assertThat(response.getStatusCode()).isEqualTo(HttpStatus.BAD_REQUEST);
    }
    // [/SQL]

    @Test
    @DisplayName("Deve retornar 400 para IllegalArgumentException")
    void deveRetornar400_quandoArgumentoIlegal() {
        // Act
        ResponseEntity<ErrorResponse> response = handler.handleIllegalArgument(
                new IllegalArgumentException("Argumento inválido"));

        // Assert
        assertThat(response.getStatusCode()).isEqualTo(HttpStatus.BAD_REQUEST);
    }

    @Test
    @DisplayName("Deve retornar 403 para AuthorizationDeniedException")
    void deveRetornar403_quandoAcessoNegado() {
        // Act
        ResponseEntity<ErrorResponse> response = handler.handleAuthorizationDenied(
                new AuthorizationDeniedException("Denied"));

        // Assert
        assertThat(response.getStatusCode()).isEqualTo(HttpStatus.FORBIDDEN);
    }

    @Test
    @DisplayName("Deve retornar 500 para exceção genérica")
    void deveRetornar500_quandoExcecaoGenerica() {
        // Act
        ResponseEntity<ErrorResponse> response = handler.handleGeneric(
                new Exception("Erro inesperado"));

        // Assert
        assertThat(response.getStatusCode()).isEqualTo(HttpStatus.INTERNAL_SERVER_ERROR);
    }

    enum Cor { AZUL, VERDE }

    @Test
    @DisplayName("Deve retornar 400 com os detalhes de ConstraintViolationException")
    void deveRetornar400_quandoParametroViolaRestricao() {
        @SuppressWarnings("unchecked")
        ConstraintViolation<Object> violacao = mock(ConstraintViolation.class);
        Path caminho = mock(Path.class);
        when(caminho.toString()).thenReturn("placa");
        when(violacao.getPropertyPath()).thenReturn(caminho);
        when(violacao.getMessage()).thenReturn("formato invalido");

        ResponseEntity<ErrorResponse> response = handler.handleConstraintViolation(
                new ConstraintViolationException(Set.of(violacao)));

        assertThat(response.getStatusCode()).isEqualTo(HttpStatus.BAD_REQUEST);
        assertThat(response.getBody().detalhes()).containsExactly("placa: formato invalido");
    }

    @Test
    @DisplayName("Deve listar os valores permitidos quando o JSON traz enum invalido")
    void deveListarValoresDoEnum_quandoJsonTemEnumInvalido() {
        InvalidFormatException causa = InvalidFormatException.from(null, "invalido", "ROXO", Cor.class);
        causa.prependPath(new Object(), "cor");
        HttpMessageNotReadableException ex = new HttpMessageNotReadableException(
                "invalido", causa, new MockHttpInputMessage(new byte[0]));

        ResponseEntity<ErrorResponse> response = handler.handleJsonError(ex);

        assertThat(response.getBody().campo()).isEqualTo("cor");
        assertThat(response.getBody().detalhes()).containsExactly("AZUL", "VERDE");
    }

    @Test
    @DisplayName("Deve retornar 400 generico para JSON ilegivel")
    void deveRetornar400_quandoJsonIlegivel() {
        HttpMessageNotReadableException ex = new HttpMessageNotReadableException(
                "invalido", new MockHttpInputMessage(new byte[0]));

        ResponseEntity<ErrorResponse> response = handler.handleJsonError(ex);

        assertThat(response.getBody().mensagem()).isEqualTo("JSON inválido");
    }

    @Test
    @DisplayName("Deve retornar 400 para parametro com tipo errado")
    void deveRetornar400_quandoTipoDoParametroErrado() {
        MethodArgumentTypeMismatchException ex = new MethodArgumentTypeMismatchException(
                "abc", Integer.class, "id", mock(MethodParameter.class), null);

        ResponseEntity<ErrorResponse> response = handler.handleTypeMismatch(ex);

        assertThat(response.getStatusCode()).isEqualTo(HttpStatus.BAD_REQUEST);
        assertThat(response.getBody().campo()).isEqualTo("id");
    }

    @Test
    @DisplayName("Deve retornar 405 para metodo HTTP nao suportado")
    void deveRetornar405_quandoMetodoNaoSuportado() {
        ResponseEntity<ErrorResponse> response = handler.handleMethodNotSupported(
                new HttpRequestMethodNotSupportedException("DELETE"));

        assertThat(response.getStatusCode()).isEqualTo(HttpStatus.METHOD_NOT_ALLOWED);
    }

    @Test
    @DisplayName("Deve retornar 404 para rota inexistente")
    void deveRetornar404_quandoRotaInexistente() {
        ResponseEntity<ErrorResponse> response = handler.handleNoResourceFound(
                new NoResourceFoundException(HttpMethod.GET, "/nao-existe"));

        assertThat(response.getStatusCode()).isEqualTo(HttpStatus.NOT_FOUND);
    }

    @Test
    @DisplayName("Deve retornar 403 para AccessDeniedException do Spring Security")
    void deveRetornar403_quandoAccessDenied() {
        ResponseEntity<ErrorResponse> response = handler.handleAuthorizationDenied(
                new AccessDeniedException("negado"));

        assertThat(response.getStatusCode()).isEqualTo(HttpStatus.FORBIDDEN);
    }

    @Test
    @DisplayName("Fabricas de 401 e 403 usam o correlationId como errorId")
    void fabricasUsamCorrelationId() {
        MDC.put("correlationId", "corr-9");
        try {
            assertThat(ErrorResponse.naoAutenticado().errorId()).isEqualTo("corr-9");
            assertThat(ErrorResponse.acessoNegado().status()).isEqualTo(403);
        } finally {
            MDC.remove("correlationId");
        }
    }
}
