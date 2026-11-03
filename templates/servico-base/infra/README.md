# infra/ do serviço servicobase

O Terraform deste serviço começa na fase em que ele é implementado. Enquanto não houver `*.tf` aqui, o CI e o CD pulam o Terraform.

## Contrato com o CD (`servico-cd.yml@v1`)

O `infra/outputs.tf` precisa expor:

| Output | Tipo | Uso no CD |
|---|---|---|
| `ecr_repository_url` | `string` | Repositório da imagem (`mecanica-servicobase`) |
| `app_config` | `map(string)` | Vira o ConfigMap `mecanica-servicobase-config` |
| `app_secrets` | `map(string)`, `sensitive = true` | Vira o Secret `mecanica-servicobase-secret` |

- Backend S3 configurado pelo CD: bucket `mecanica-tfstate-<accountId>`, key `fiap-soat-mecanica-servicobase/terraform.tfstate`. O `backend.tf` fica só com `backend "s3" {}`.
- Provider AWS `~> 6.0`, `required_version = ">= 1.10.0, < 2.0.0"`.
- O CD passa `TF_VAR_mp_access_token` e `TF_VAR_mp_webhook_secret`. Variáveis não declaradas são ignoradas.
- Nomes de filas, tópicos, RDS e SSM seguem a tabela 3.4 do plano da F1.

### Chaves de mensageria no `app_config`

As chaves do `app_config` viram variáveis de ambiente do pod (`envFrom`).

| Chave | Valor | Propriedade |
|---|---|---|
| `APP_MESSAGING_CONSUMIDOR_FILAS` | URLs das filas consumidas, separadas por vírgula | `app.messaging.consumidor.filas` |
| `APP_MESSAGING_DLQS` | URLs das DLQs dessas filas | `app.messaging.dlqs` (gauge `dlq.depth`) |
| `MESSAGING_DESTINO_<NOME>` | ARN do tópico ou URL da fila | declarada no `application.properties` do serviço como `app.messaging.destinos.<nome>=${MESSAGING_DESTINO_<NOME>:}` |

Os destinos usam variável explícita porque a ligação relaxada do Spring não preserva o `-` das chaves de mapa vindas de variáveis de ambiente (`execucao-comandos` viraria `execucao.comandos`). A role do pod precisa de `sns:Publish` nos tópicos e de `sqs:SendMessage`, `ReceiveMessage`, `DeleteMessage` e `GetQueueAttributes` nas filas.
