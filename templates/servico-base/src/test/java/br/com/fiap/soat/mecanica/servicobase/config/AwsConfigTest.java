package br.com.fiap.soat.mecanica.servicobase.config;

import org.junit.jupiter.api.Test;
import software.amazon.awssdk.auth.credentials.DefaultCredentialsProvider;
import software.amazon.awssdk.auth.credentials.StaticCredentialsProvider;
import software.amazon.awssdk.services.sns.SnsClient;
import software.amazon.awssdk.services.sqs.SqsClient;

import static org.assertj.core.api.Assertions.assertThat;

class AwsConfigTest {

    @Test
    void comEndpointECredenciaisUsaLocalStack() {
        AwsConfig config = new AwsConfig("us-east-1", "http://localhost:4566", "test", "test");

        assertThat(config.credenciais()).isInstanceOf(StaticCredentialsProvider.class);
        try (SnsClient sns = config.snsClient(); SqsClient sqs = config.sqsClient()) {
            assertThat(sns.serviceClientConfiguration().endpointOverride()).hasValueSatisfying(
                    uri -> assertThat(uri).hasToString("http://localhost:4566"));
            assertThat(sqs.serviceClientConfiguration().region().id()).isEqualTo("us-east-1");
        }
    }

    @Test
    void semEndpointUsaCadeiaPadraoDeCredenciais() {
        AwsConfig config = new AwsConfig("us-east-1", "", "", "");

        assertThat(config.credenciais()).isInstanceOf(DefaultCredentialsProvider.class);
        try (SnsClient sns = config.snsClient()) {
            assertThat(sns.serviceClientConfiguration().endpointOverride()).isEmpty();
        }
    }
}
