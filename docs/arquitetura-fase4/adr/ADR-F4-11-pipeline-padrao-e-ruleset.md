# ADR-F4-11: Pipeline padrão por reusable workflows `@v1` e ruleset com 0 aprovações

- **Status:** Aceito
- **Data:** 2026-11-02 (implementado e validado na F1)
- **Escopo:** os 7 repositórios
- **Implementação:** `.github/workflows/{servico-ci,terraform-ci,servico-cd}.yml` (tags `v1` e `v1.0.0`), `scripts/aplicar-ruleset.sh` e `scripts/ruleset-main.json`

## Contexto

Os 7 repositórios precisam de CI/CD independente e `main` protegida. Escrever a mesma lógica de build, Sonar e deploy em cada repositório multiplicaria as correções por sete. O trabalho é individual, e o GitHub não deixa o autor aprovar o próprio PR.

## Decisão

- **Workflows:** cada repositório tem o seu `ci.yml` (e `cd.yml` nos serviços), que só chama um **reusable workflow** do `-k8s` pela tag móvel `@v1`, com `secrets: inherit`. Uma mudança compatível é validada antes no `-auth` e só então a tag é movida; uma incompatível vira `v2`.
- **Ruleset `main-protegida`** nos 7:
  - PR obrigatório, com **0 aprovações**;
  - checks obrigatórios `ci / build` + `SonarCloud Code Analysis` nos 5 projetos Java, ou `ci / terraform` no `-db` e no `-k8s`;
  - merge só por squash, sem bypass (nem o dono da org) e sem exigir a branch atualizada (`strict=false`).
- **Ordem de aplicação:** primeiro push, depois CI verde e por último o ruleset. O `aplicar-ruleset.sh` confere os checks no último commit antes de aplicar.

## Consequências

- **Proteção comprovada:** no T16, o PR #2 do Identity ficou bloqueado com um teste vermelho e, depois, com o Quality Gate reprovado por código novo sem teste. Só entrou, por auto-merge, quando os dois checks ficaram verdes.
- **0 aprovações:** é a única configuração possível sozinho. A garantia vem dos checks, e não de revisão humana.
- **Dependência do `-k8s`:** os 7 repositórios dependem da tag `v1`, e um erro nela quebra todos. Por isso a validação prévia no `-auth`.
- **Lições do SonarCloud na F1:** a primeira análise de cada projeto sai com gate `NONE`, e o `-Dsonar.qualitygate.wait=true` a trata como falha; um rerun resolve. E a *Automatic Analysis* ligada derruba o CI, o que aconteceu no Execução.

**Alternativas rejeitadas:**
- workflows copiados em cada repositório (7 cópias para manter);
- 1 aprovação com uma segunda conta (aprovação de fachada);
- branch protection clássica (o ruleset é versionável por API e se aplica igual nos 7).
