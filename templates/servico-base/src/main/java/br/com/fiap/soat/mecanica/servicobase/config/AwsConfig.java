package br.com.fiap.soat.mecanica.servicobase.config;

import org.springframework.beans.factory.annotation.Value;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import software.amazon.awssdk.auth.credentials.AwsBasicCredentials;
import software.amazon.awssdk.auth.credentials.AwsCredentialsProvider;
import software.amazon.awssdk.auth.credentials.DefaultCredentialsProvider;
import software.amazon.awssdk.auth.credentials.StaticCredentialsProvider;
import software.amazon.awssdk.awscore.client.builder.AwsClientBuilder;
import software.amazon.awssdk.regions.Region;
import software.amazon.awssdk.services.sns.SnsClient;
import software.amazon.awssdk.services.sqs.SqsClient;

import java.net.URI;

/**
 * Clientes do AWS SDK v2. No EKS usam a cadeia padrao de credenciais (role do node);
 * com app.aws.endpoint preenchido (LocalStack), usam o endpoint e as credenciais fixas do perfil local.
 */
@Configuration
public class AwsConfig {

    private final Region region;
    private final String endpoint;
    private final String accessKeyId;
    private final String secretAccessKey;

    public AwsConfig(
            @Value("${app.aws.region}") String region,
            @Value("${app.aws.endpoint:}") String endpoint,
            @Value("${app.aws.access-key-id:}") String accessKeyId,
            @Value("${app.aws.secret-access-key:}") String secretAccessKey) {
        this.region = Region.of(region);
        this.endpoint = endpoint;
        this.accessKeyId = accessKeyId;
        this.secretAccessKey = secretAccessKey;
    }

    @Bean(destroyMethod = "close")
    public SnsClient snsClient() {
        return configurar(SnsClient.builder()).build();
    }

    @Bean(destroyMethod = "close")
    public SqsClient sqsClient() {
        return configurar(SqsClient.builder()).build();
    }

    <B extends AwsClientBuilder<B, ?>> B configurar(B builder) {
        builder.region(region).credentialsProvider(credenciais());
        if (!endpoint.isBlank()) {
            builder.endpointOverride(URI.create(endpoint));
        }
        return builder;
    }

    AwsCredentialsProvider credenciais() {
        if (!accessKeyId.isBlank() && !secretAccessKey.isBlank()) {
            return StaticCredentialsProvider.create(AwsBasicCredentials.create(accessKeyId, secretAccessKey));
        }
        return DefaultCredentialsProvider.builder().build();
    }
}
