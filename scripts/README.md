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

Os scripts que alteram a org (repos, secrets, ruleset) são revisados antes de rodar.
