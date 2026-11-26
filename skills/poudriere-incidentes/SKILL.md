---
name: poudriere-incidentes
description: Use quando build interrompe a operacao, disco esta cheio, servico cai ou ha risco a packages.
---

# Resposta a incidentes

**Versao:** 1.0.0  
**Projeto:** Poudriere / FreeBSD  
**Acionamento:** Use quando build interrompe a operacao, disco esta cheio, servico cai ou ha risco a packages.

## Politica

Siga `AGENTS.md`. Realize consultas sem alteracao antes de comandos mutaveis. Requer autorizacao expressa para alterar o host. Use `vi` para edicoes, mantenha comentarios em ASCII sem acentos nos arquivos de configuracao, incremente versoes e documente rollback.

## Procedimento


1. Tratar logs, tempo e estado como evidencia; nao iniciar limpeza imediata.
2. Classificar gravidade: indisponibilidade de repo, risco de perda de dados, falha de build isolada ou alerta de recurso.
3. Preservar metadados, ultimo repositorio valido e logs; identificar processos e mounts antes de encerramentos.
4. Propor contencao minima, plano de restauracao e verificacao posterior.
5. Se o disco estiver completamente cheio, verificar onde ha espaco e quais operacoes nao criam arquivos temporarios; nao rodar `distclean` cegamente.
6. Confirmar retorno dos clientes `pkg` e acesso Nginx apos a recuperacao.

```sh
# Primeira coleta
zpool status
zfs list -o name,used,avail,mountpoint
df -h
swapinfo -h
ps auxww
poudriere jail -l
```

Nao matar processos, desmontar jails, reiniciar host nem destruir datasets sem aprovacao e analise de impacto. Reportar explicitamente o que ainda nao foi validado.

## Entrega obrigatoria

Indicar ambiente confirmado, evidencias, comandos efetivamente executados, comandos apenas propostos, riscos, verificacoes, versao e rollback. Nunca declarar sucesso de operacao que nao foi executada.
