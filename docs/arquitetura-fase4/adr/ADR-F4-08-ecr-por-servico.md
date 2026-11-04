# ADR-F4-08: Um repositório ECR por serviço, criado no `infra/` do próprio serviço

- **Status:** Aceito
- **Data:** 2026-11-04 (implementado na F2 no Identity; OS, Billing e Execução seguem o mesmo padrão)
- **Escopo:** os 4 serviços e o `servico-cd.yml`
- **Implementação:** `fiap-soat-mecanica-identity/infra/ecr.tf`; output `ecr_repository_url` (contrato infra → CD); passos "Resolver imagem e versão" e "Build e push" do `servico-cd.yml`

## Contexto

Cada serviço publica uma imagem por deploy. O ambiente é destruído e recriado a cada janela, e o `workflow_dispatch` do CD reconstrói o mesmo SHA (redeploy depois de uma correção de infra ou de credencial).

## Decisão

- **Um repositório por serviço** (`mecanica-<svc>`), declarado no `infra/` do serviço. O CD lê a URL pelo output `ecr_repository_url`, depois do `terraform apply`.
- **Tag da imagem:** o SHA completo do commit. A `VERSION` do deploy usa os 7 primeiros caracteres.
- **`image_tag_mutability = "MUTABLE"`:** o redeploy do mesmo SHA faz push da mesma tag. Com tags imutáveis, o push falharia.
- **`force_delete = true`:** o `terraform destroy` diário apaga o repositório com imagens dentro.
- **`scan_on_push`** ligado e **lifecycle policy** que mantém as 10 imagens mais recentes.

## Alternativas consideradas

| Alternativa | Motivo da rejeição |
|---|---|
| ECR criado pelo `-k8s` para todos | Acoplaria o `-k8s` à lista de serviços, e um serviço novo exigiria PR em dois repositórios |
| Um repositório só, com a tag `<svc>-<sha>` | Mistura ciclo de vida e lifecycle policy, e o destroy de um serviço afetaria os outros |
| Tags imutáveis + tag nova por redeploy (`<sha>-<run>`) | A tag deixaria de identificar o commit sem ganho real, porque cada janela recria o repositório do zero |
| GHCR | A imagem sairia da conta, e o pull nos nodes exigiria `imagePullSecret` com PAT |

## Consequências

- **Serviços independentes:** o serviço é dono do seu repositório, como já é do seu banco (ADR-F4-05) e das suas filas (ADR-F4-03).
- **Primeiro deploy de cada janela:** o CD precisa do `apply` antes do push. A ordem está no `servico-cd.yml`.
- **Sem histórico entre janelas:** as imagens somem no destroy. Um redeploy reconstrói a partir do SHA, o que é aceito.
- **Tag mutável:** a tag não garante, sozinha, que a imagem é aquela do commit. Dentro de uma janela, só o CD faz push, e sempre a partir do SHA testado.
