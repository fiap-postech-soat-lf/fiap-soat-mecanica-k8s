# ADR-F4-14: Configuração entre repositórios via SSM Parameter Store

- **Status:** Aceito
- **Data:** 2026-11-02 (implementado na F1 no `servico-cd.yml` e no `bootstrap-state.sh`)
- **Escopo:** os 7 repositórios
- **Implementação:** `servico-cd.yml` (lê `/mecanica/k8s/cluster-name` e `/mecanica/auth/api-url`), `scripts/bootstrap-state.sh`; os parâmetros são criados a partir da F2

## Contexto

Os repositórios dependem de valores que outros criam. O CD dos serviços precisa do nome do cluster (`-k8s`) e da URL da API (`-auth`), o OS precisa do ARN do tópico de outro serviço, e todos precisam do bucket de state. Na Fase 3 do grupo, esses valores eram copiados à mão em GitHub Variables. No Academy, a conta pode mudar, e o ambiente é destruído e recriado a cada janela de integração.

## Decisão

- **Parâmetros:** quem cria um recurso publica o seu identificador em `/mecanica/<repo-curto>/<chave>`, no Terraform do próprio repositório. Exemplos: `/mecanica/k8s/cluster-name`, `/mecanica/k8s/nlb-dns`, `/mecanica/auth/api-url`, `/mecanica/os/os-eventos-topic-arn` e `/mecanica/identity/jwt-secret-arn`. Quem consome lê o parâmetro no momento do uso.
- **Bucket de state:** não é guardado em lugar nenhum. É sempre `mecanica-tfstate-<accountId>`, com o account ID vindo de `aws sts get-caller-identity`, e a key é `<nome-do-repo>/terraform.tfstate`.
- **Ausência como sinal:** sem o `/mecanica/k8s/cluster-name`, o CD termina verde com o aviso "EKS desligado". A falta do parâmetro sinaliza que o ambiente está desligado, e não um erro. O comportamento foi visto no T16.

## Consequências

- **Sem cópia manual:** trocar de conta ou recriar o ambiente não exige atualizar variável em 7 repositórios; basta o `atualizar-credenciais.sh`.
- **Ordem de provisionamento:** importa (B4 do plano mestre). Um consumidor que sobe antes do produtor do parâmetro falha ou, no caso do CD, pula o deploy.
- **Acoplamento só por nome:** o acoplamento entre repositórios fica no nome do parâmetro, documentado em `docs/contratos/convencoes.md` (tabela 2.4).

**Alternativas rejeitadas:**
- GitHub Variables manuais (regravação a cada conta);
- `terraform_remote_state` (acopla ao layout do state de outro repositório e exige conhecer bucket e key);
- valores fixos nos workflows.
