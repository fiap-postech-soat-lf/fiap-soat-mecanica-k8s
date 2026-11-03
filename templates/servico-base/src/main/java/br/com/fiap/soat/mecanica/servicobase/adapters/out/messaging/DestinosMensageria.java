package br.com.fiap.soat.mecanica.servicobase.adapters.out.messaging;

import org.springframework.boot.context.properties.ConfigurationProperties;

import java.util.Map;

/**
 * Nomes logicos dos destinos de publicacao ({@code app.messaging.destinos.<nome>=<ARN do topico ou URL da fila>}).
 * Cada servico declara os seus no application.properties, com o valor vindo do ConfigMap
 * (ex.: {@code app.messaging.destinos.execucao-comandos=${MESSAGING_DESTINO_EXECUCAO_COMANDOS:}}).
 */
@ConfigurationProperties("app.messaging")
public record DestinosMensageria(Map<String, String> destinos) {

    public DestinosMensageria {
        destinos = destinos == null ? Map.of() : Map.copyOf(destinos);
    }

    /** ARN ou URL do destino; falha se o nome nao estiver configurado. */
    public String resolver(String nome) {
        String valor = destinos.get(nome);
        if (valor == null || valor.isBlank()) {
            throw new IllegalStateException("Destino de mensageria nao configurado: app.messaging.destinos." + nome);
        }
        return valor;
    }

    /** Nome da fila a partir da URL ({@code https://sqs.../000000000000/mecanica-os-saga-respostas}). */
    public static String nomeDaFila(String url) {
        return url.substring(url.lastIndexOf('/') + 1);
    }
}
