# scripts

Scripts de administração da org `fiap-postech-soat-lf` e da conta AWS Academy. Todos são idempotentes: rodar de novo não duplica nada.

| Script | Tarefa | Quando rodar |
|---|---|---|
| `criar-repos.sh` | T03 | Uma vez, na F1 |
| `atualizar-credenciais.sh` | T04 | No início de **toda** sessão do Academy (`--fixos` só quando um segredo fixo mudar) |
| `bootstrap-state.sh` | T05 | Uma vez por conta AWS |
| `aplicar-ruleset.sh` + `ruleset-main.json` | T10 | Depois do push inicial de cada repositório |
| `novo-servico.sh` | T12 | Para gerar ou regenerar um serviço a partir do template |
| `comparar-esqueleto.sh` | T12 | Para conferir se um serviço divergiu do template |
| `subir-ambiente.sh` | F2 T05 | Início de cada janela com o EKS: credenciais → `cluster.yml` → CDs de `identity`, `execucao`, `billing` e `os` (quem tiver `infra/*.tf`) → CD do `-auth` → `smoke-borda.sh`, com o tempo de cada etapa |
| `destruir-ambiente.sh` | F2 T05 | Fim de **toda** janela: dispara o `destruir-ambiente.yml`, espera e roda o `verificar-orfaos.sh` |
| `verificar-orfaos.sh` | F2 T05 | Depois do destroy (saída 0 = conta limpa, 1 = sobrou recurso, 2 = erro de consulta). Só leitura |
| `smoke-borda.sh` | F2 T05 | Com o ambiente ligado: verificações 5–21 (F2 + CP1 + CP2 + F5): 401, 403, 200 com `x-user-*`, rota pública, logins do Identity, a borda até o OS, o Execução e o Billing e as rotas `/pecas` e `/execucoes/fila` do Execução. Só leitura |
| `demo-saga-execucao.sh` | F5 T08 | Com o ambiente ligado: abre uma OS até `EM_DIAGNOSTICO` com o Execução real, monta o diagnóstico com uma peça do seed, confere a reserva (`qtdDisponivel − 2`) e o `GerarOrcamento` de R$ 159,80, cancela e confere a devolução ao estoque; depois cancela uma segunda OS sem reserva (F5-b) e confere as DLQs e o log. **Escreve dados** (prova da F5; substitui o `demo-saga-os.sh`, que simulava o Execução) |
| `destruir-stack.sh` | F2 T05 | Usado pelo `destruir-ambiente.yml`; à mão, destrói um stack pela key do state (pula state vazio) |
| `lib-workflows.sh` | F2 T05 | Funções comuns (`disparar_e_esperar`), carregado com `source` |

Os scripts que alteram a org (repos, secrets, ruleset) ou a conta AWS são revisados antes de rodar. `subir-ambiente.sh`, `destruir-ambiente.sh` e `destruir-stack.sh` aceitam `--dry-run`.
