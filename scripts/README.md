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
| `subir-ambiente.sh` | F2 T05 | Início de cada janela com o EKS: credenciais → `cluster.yml` → CDs de `identity`, `execucao`, `billing` e `os` (quem tiver `infra/*.tf`) → CD do `-auth` → `smoke-borda.sh` → `e2e.yml` do `-os` (F7-d; `--sem-e2e` pula), com o tempo de cada etapa |
| `caos.sh` | F7 T02 | Com o ambiente ligado: `execucao-fora [--esgotar]` escala o Execução para 0, abre uma OS, publica uma **cópia** do `AbrirDiagnostico` (mesmo `messageId`), espera o reenvio do OS por timeout, devolve o Execução e confere `EM_DIAGNOSTICO`, uma só ordem, `mensagem_duplicada`, `comando_reemitido` e `resposta_fora_do_passo`; com `--esgotar` (`SAGA_TIMEOUT_COMANDO=PT30S` no OS só durante a cena) a OS termina `CANCELADA` com Saga `FALHOU`. `mensagem-envenenada [--manter]` manda um corpo que não é JSON para a `mecanica-execucao-comandos`, espera a DLQ chegar a 1 e a limpa (sem `--manter`). `limpar-dlq [<fila-dlq>]` faz o `purge-queue` da DLQ (padrão `mecanica-execucao-comandos-dlq`) e confere 0; é o par do `--manter`. `webhook-invalido [<n>]` manda `n` (padrão 5) `POST /webhooks/mercadopago` sem `x-signature`, esperando 401, para disparar o monitor do webhook. Um `trap` desfaz réplicas e env. **Escreve dados** |
| `datadog-aplicar.sh` | F8 T02 | `[--conferir] [--dry-run] [--conta-nova]`: valida os JSON de `observability/datadog/`, os monitores (`/monitor/validate`) e as métricas do `metricas.txt`; sem flag, liga os percentis das distribuições e faz o upsert dos 3 dashboards e dos 6 monitores. Nunca apaga. `--conta-nova` (conta sem métricas) transforma métrica obrigatória ausente em aviso. Lê `DATADOG_API_KEY`, `DATADOG_APP_KEY` e `DD_SITE` do ambiente; roda pelo workflow `datadog.yml`. Não toca a AWS |
| `destruir-ambiente.sh` | F2 T05 | Fim de **toda** janela: dispara o `destruir-ambiente.yml`, espera e roda o `verificar-orfaos.sh` |
| `verificar-orfaos.sh` | F2 T05 | Depois do destroy (saída 0 = conta limpa, 1 = sobrou recurso, 2 = erro de consulta). Só leitura |
| `smoke-borda.sh` | F2 T05 | Com o ambiente ligado: verificações 5–24 (F2 + CP1 + CP2 + F5 + F6): 401, 403, 200 com `x-user-*`, rota pública, logins do Identity, a borda até o OS, o Execução e o Billing as rotas `/pecas` e `/execucoes/fila` do Execução e as do Billing (22–24: 404 e 403 do Billing em `/orcamentos/por-os` e 401 do webhook sem assinatura). Só leitura |
| `demo-saga-execucao.sh` | F5 T08 | Com o ambiente ligado: abre uma OS até `EM_DIAGNOSTICO` com o Execução real, monta o diagnóstico com uma peça do seed, confere a reserva (`qtdDisponivel − 2`) e o orçamento `GERADO` de R$ 159,80 no Billing real, cancela e confere o orçamento `CANCELADO` e a devolução ao estoque; depois cancela uma segunda OS sem reserva (F5-b) e confere as DLQs e o log. **Escreve dados** (prova da F5; substitui o `demo-saga-os.sh`, que simulava o Execução) |
| `demo-saga-billing.sh` | F6 T07 | Com o ambiente ligado: leva três OS pelo Billing real e pelo Mercado Pago — orçamento `GERADO` (R$ 159,80, 24 h), 403 de outro cliente, aprovação com baixa real no estoque, pagamento APRO (OS `ENTREGUE`), pagamento OTHE (`RECUSADO`), nova cobrança e APRO, e recusa do orçamento com compensação. Os pagamentos são **feitos à mão** no navegador (`PAGAMENTO_TIMEOUT`, padrão 600 s). `--so-apro` roda só os passos 1–6 e 10 (ensaio do pagamento, F7-j). `--help` lista os passos. **Escreve dados** (prova do DoD da F6) |
| `destruir-stack.sh` | F2 T05 | Usado pelo `destruir-ambiente.yml`; à mão, destrói um stack pela key do state (pula state vazio) |
| `lib-workflows.sh` | F2 T05 | Funções comuns (`disparar_e_esperar`), carregado com `source` |

Os scripts que alteram a org (repos, secrets, ruleset) ou a conta AWS são revisados antes de rodar. `subir-ambiente.sh`, `destruir-ambiente.sh` e `destruir-stack.sh` aceitam `--dry-run`.
