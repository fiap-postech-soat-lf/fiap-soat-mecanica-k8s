# RFC-F4-03: Capacidade e custo do ambiente no AWS Academy

- **Status:** Aprovado
- **Data:** 2026-11-04 (números medidos na janela de integração da F2, D7). Atualizada em 2026-11-06 com o custo medido do D8 e do CP2 (F5, T00) e em 2026-11-07 com o da janela da F5 (F6, T00 e T08)
- **Escopo:** `-k8s` (cluster e scripts do ambiente) e o planejamento das janelas F3–F9
- **Base:** RFC-001 do `fiap-soat-mecanica-api-k8s` do grupo (EKS no Learner Lab), que continua valendo para as restrições do Academy

## Resumo

O ambiente da Fase 4 não fica ligado: cada janela de integração sobe tudo do zero com `scripts/subir-ambiente.sh` e destrói tudo no fim com `scripts/destruir-ambiente.sh`. Esta RFC registra quanto tempo isso leva, quanto o cluster comporta e quanto custa por hora. Esses números dimensionam as janelas restantes dentro do crédito de US$ 50.

## Ambiente medido (F2)

| Componente | Configuração |
|---|---|
| EKS | 1.37, control plane gerenciado |
| Node group | 3 × `t3.medium` (2 vCPU, 4 GiB), desired 3 / min 1 / max 3, launch template IMDSv2 com hop limit 2 |
| Add-ons no cluster | Traefik (chart 42.3.0, NodePort 30090), OpenTelemetry Operator 0.114.0, collector em DaemonSet, `metrics-server`, `whoami` de diagnóstico |
| Borda | NLB público, HTTP API, Lambda Authorizer (Java 21, 512 MB) |
| Serviços | Identity (1 RDS `db.t3.micro`, ECR). Do CP2 em diante: Identity, OS e Billing (3 RDS) e o Execução (6 tabelas DynamoDB on-demand) |

## Tempo de subida e destruição

| Etapa | Estimado no plano | 1º ciclo (com correções no meio) | **2º ciclo (limpo, um comando)** |
|---|---|---|---|
| `cluster.yml` (EKS, nodes, helm, NLB, manifestos, smoke) | 25–30 min | ≈ 14 min, em duas execuções (PR #12) | **12m46s**: EKS 8m44s, NLB 2m52s em paralelo, node group 1m47s, helm ~20s cada, manifestos e smoke ~20s |
| `cd.yml` do Identity (RDS, ECR, build, push, rollout) | 11–15 min | 10m27s (só RDS e secret do banco no Terraform; RDS 5m18s) | **10m14s** (RDS 5m47s) |
| `cd.yml` do `-auth` (build, Lambda, API Gateway, smoke) | 3 min | 54s (39 recursos) | **1m16s** |
| `smoke-borda.sh` | 1 min | < 1 min (8/8 PASS) | **16s** (8/8 PASS) |
| **Total do `subir-ambiente.sh`** | 40–50 min | — | **24m47s** |
| `destruir-ambiente.sh` (workflow + `verificar-orfaos.sh`) | 20–25 min | 15m30s (borda 32s, serviços 2m23s, cluster 10m37s, órfãos 36s) | **15m01s** (workflow 14m22s). Nenhum órfão nos dois ciclos |

Um ciclo completo (subir, validar e destruir) cabe em **~45 min**, com folga dentro das 4 h de credencial do Academy. A subida é dominada pelo control plane do EKS e pelo RDS, que o Terraform cria em série porque o RDS depende do SG do cluster publicado no SSM. A partir da F4 entram mais 2 RDS e o DynamoDB. Os RDS de OS e Billing são criados em CDs separados, em sequência, por isso cada serviço com RDS acrescenta ≈ 10,5 min (o CD do Identity medido), e o Execução, sem RDS, ≈ 5 min. **Projeção da F6 em diante:** ≈ 25 + 10,5 (OS) + 10,5 (Billing) + 5 (Execução) ≈ **51 min**. A Identity Spring Boot leva 76 s para iniciar com 250m de CPU de request, o que domina o rollout.

## Capacidade do cluster

Medido com `kubectl describe nodes` depois da subida:

| Item | Por node | Total (3 nodes) |
|---|---|---|
| Pods alocáveis (limite do VPC CNI no `t3.medium`) | 17 | 51 |
| Pods em uso | 5 / 5 / 7 | 17 (33%) |
| CPU requests alocados (de 1930m por node) | 350m / 350m / 710m | 1410m de 5790m (24%) |
| Memória requests alocada (de ~3,2 Gi por node) | 456 Mi / 456 Mi / 796 Mi | 1708 Mi de ~9,6 Gi (17%) |

Por pod: Identity 250m / 384 Mi (limite de 768 Mi); collector 100m / 256 Mi por node; echo 10m / 16 Mi. O scheduler colocou coredns ×2, echo, Identity e um collector no mesmo node (36% de CPU).

**Projeção da F6 em diante** (4 serviços com o perfil do Identity, HPA de 1 a 3 réplicas):

| Cenário | Pods | CPU requests | Memória requests |
|---|---|---|---|
| 1 réplica por serviço (mínimo do HPA) | 20 de 51 | 2160m (37%) | 2860 Mi (29%) |
| 3 réplicas por serviço (máximo do HPA) | 28 de 51 | 4160m (72%) | 5932 Mi (60%) |

Os 3 nodes comportam até o máximo do HPA abaixo de 80% de CPU. O limite que aperta primeiro é o de CPU, e não o de pods.

## Custo

**Estimativa por hora** (preços on-demand de `us-east-1`):

| Recurso | US$/h |
|---|---|
| EKS control plane | 0,10 |
| 3 × `t3.medium` | 0,125 |
| NLB (hora + LCU mínima) | ~0,03 |
| RDS `db.t3.micro` (1, na F2) | 0,018 |
| EBS dos nodes e IPs públicos | ~0,06 |
| **Total F2** | **≈ 0,33–0,35** |
| Com 3 RDS (F6 em diante) | ≈ 0,40 |

API Gateway, Lambda, Secrets Manager, SSM, ECR e CloudWatch custam centavos por janela no volume do projeto.

**Medido pela diferença de saldo do Academy:**

| Item | Valor |
|---|---|
| Saldo antes da janela (2026-11-04, 22:12 UTC) | US$ 50,00 |
| Saldo depois da janela (reconferido em 2026-11-05) | US$ 49,50 (painel: "Used US$ 0.5 of US$ 50"). O painel atualiza com atraso de horas |
| Duração da janela com recurso ligado | ≈ 2 h 05 min: 1º ciclo de ~22:15 a ~23:40 UTC (inclui ~20 min com o EKS e o NLB ligados sem nodes, por causa das falhas corrigidas nos PRs #12 do `-k8s` e #5 do Identity) e 2º ciclo de ~23:59 a ~00:39 UTC |
| Custo medido da janela | **US$ 0,50** (a estimativa era ≈ US$ 0,70) |
| Custo medido por hora | ≈ **US$ 0,24/h** (US$ 0,50 ÷ ≈ 2,1 h), abaixo dos ≈ US$ 0,35/h estimados |

> O painel do Learner Lab atualiza o saldo **só na virada do dia**, com uma casa decimal (± US$ 0,05). Por isso o saldo do dia anterior é anotado no início de cada fase (T00), e não logo depois da janela.

**Janelas do D8 (CP1) e do CP2 (medidas em 2026-11-06):** o painel ficou em US$ 49,50 em 2026-11-05 e só refletiu as duas janelas na virada do dia: "Used US$ 1.3 of US$ 50", ou seja, **saldo de US$ 48,70**. A queda de US$ 0,80 desde o D7 foi rateada pelas horas ligadas de cada janela (do início do `subir-ambiente.sh` ao fim do `destruir-ambiente.sh`, tiradas dos logs em `evidencias/`):

| Janela | Ambiente | Horas ligadas | Custo rateado | Estimativa anterior |
|---|---|---|---|---|
| D7 (F2) | 1 RDS | ≈ 2,1 h | US$ 0,50 (≈ US$ 0,24/h) | ≈ US$ 0,70 |
| D8 (CP1) | — | ≈ 0,88 h | ≈ **US$ 0,25** | ≈ US$ 0,45 |
| CP2 | 3 RDS | ≈ 1,92 h | ≈ **US$ 0,55** | US$ 0,55–0,90 |
| **Total até o CP2** | | | **US$ 1,30** | |

A taxa conjunta do D8 e do CP2 é de ≈ **US$ 0,29/h** (US$ 0,80 ÷ ≈ 2,8 h), com ± US$ 0,05 no total por causa do arredondamento do painel. É o valor a usar nas próximas janelas. O CP2, com 3 RDS, custou menos do que os ≈ US$ 0,40/h estimados pela tabela de preços; o que mais pesa na conta é o tempo ligado.

**Janela da F5 (D9, medida em 2026-11-07):** o ambiente é o do CP2 (3 RDS) mais as 6 tabelas DynamoDB on-demand, que custam centavos com o tráfego da demo. Ficou ligado de 22:28:44 a 00:03:43 UTC, **≈ 1 h 35** (≈ 1,58 h). O painel do Learner Lab, lido depois da virada do dia, mostrou "Used US$ 1.7 of US$ 50", ou seja, **saldo de US$ 48,30**. A queda de US$ 0,40 desde os US$ 48,70 anteriores é o custo da janela: **US$ 0,40** (≈ **US$ 0,25/h**), abaixo da estimativa de ≈ US$ 0,55.

Com a F5, a taxa conjunta do D8, do CP2 e da F5 é de ≈ **US$ 0,27/h** (US$ 1,20 ÷ ≈ 4,4 h), com ± US$ 0,05 por causa do arredondamento do painel. É o valor a usar daqui em diante. O **total do projeto até a F5 é US$ 1,70** (saldo US$ 48,30).

**Janela da F6 (D11), estimativa:** o mesmo ambiente da F5, mais 2 secrets (centavos). Com ≈ 2 h ligado (o roteiro é mais longo por causa dos três pagamentos manuais), a US$ 0,27/h: **≈ US$ 0,55** (US$ 0,50–0,60). O projeto fica em ≈ US$ 2,25 até o fim da F6. O valor medido só sai no D12, porque o painel atualiza na virada do dia.

## Decisão

- **Ambiente efêmero por janela:** subir com `subir-ambiente.sh` e destruir com `destruir-ambiente.sh` ao fim de **toda** janela, sem exceção. O ambiente não fica ligado entre dias.
- **Node group com max 3:** o corte 1 (HPA sem demonstração) dispensa a folga para escalar. Se a projeção de capacidade passar de ~80% do alocável, o próximo passo é subir o desired para 4, e não trocar o tipo de instância.
- **Orçamento das janelas restantes** (recalibrado em 2026-11-07 para ≈ US$ 0,27/h medidos; as horas das janelas futuras são estimativas, pelo calendário de cada fase):

  | Janela | Horas ligadas | US$/h | US$ |
  |---|---|---|---|
  | D7, D8, CP2 e D9 (F5) (medido) | ≈ 6,5 | 0,24–0,29 | 1,70 |
  | D11 (F6: Mercado Pago, CP3) | ~2 | 0,27 | ~0,55 |
  | D12 (F7: E2E) | ~5 | 0,27 | ~1,35 |
  | D13 (F8: caos, dashboards) | ~6 | 0,27 | ~1,60 |
  | D14 (F9: gravação) | ~4 | 0,27 | ~1,10 |
  | **Total** | **~23,5** | | **≈ US$ 6,30** |

  Mesmo com o dobro das horas das janelas que faltam (falhas e ensaio), o total fica abaixo de US$ 12, menos de um quarto do crédito. O risco real é esquecer o ambiente ligado (≈ US$ 6,50 por dia a US$ 0,27/h), e não o custo das janelas.

## Alternativas consideradas

| Alternativa | Motivo da rejeição |
|---|---|
| Ambiente ligado de forma contínua (D8–D14) | ≈ US$ 0,40/h × 24 h × 7 dias ≈ US$ 67, acima do crédito |
| Ambiente ligado e escalado para 0 nodes entre janelas | Economiza só os nodes. O control plane (US$ 0,10/h), o NLB e os RDS continuam cobrando, e as credenciais do Academy expiram de qualquer jeito |
| Nodes `t3.small` | 11 pods por node no VPC CNI e 2 GiB de memória, o que não comporta os serviços Java com o agente OTel |
| Nodes spot | Interrupção no meio de uma demonstração ou gravação. A economia (~US$ 0,08/h) não compensa |

## Riscos

- **Credenciais de 4 h:** a subida leva ~45 min e o destroy ~20 min. Uma janela longa exige *Start Lab* e `atualizar-credenciais.sh` no meio, nunca durante um `apply`/`destroy`.
- **Esquecer o ambiente ligado:** ≈ US$ 7–10 por dia (US$ 0,29/h medidos a US$ 0,40/h estimados). Mitigação: o `destruir-ambiente.sh` faz parte do fim de toda janela, e o `verificar-orfaos.sh` confirma que não sobrou recurso.
