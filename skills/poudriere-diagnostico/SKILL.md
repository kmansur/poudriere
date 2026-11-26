---
name: poudriere-diagnostico
description: Use quando houver erro de compilacao, pacote falhando, logs de Rust, Node, mesa ou dependencia.
---

# Diagnostico de compilacao e falhas

**Versao:** 1.0.0  
**Projeto:** Poudriere / FreeBSD  
**Acionamento:** Use quando houver erro de compilacao, pacote falhando, logs de Rust, Node, mesa ou dependencia.

## Politica

Siga `AGENTS.md`. Realize consultas sem alteracao antes de comandos mutaveis. Requer autorizacao expressa para alterar o host. Use `vi` para edicoes, mantenha comentarios em ASCII sem acentos nos arquivos de configuracao, incremente versoes e documente rollback.

## Procedimento


1. Recolher jail, ports tree, origem do port, horario e comando exato da build.
2. Confirmar recursos e log da build. Comparar primeira falha real com as mensagens finais de cascata.
3. Em Rust e Node, verificar sinais de OOM, swap, limite de CPU, paralelismo interno e falha de link sem assumir a causa.
4. Conferir build anterior, opcoes e variaveis efetivas antes de recomendar rebuild.
5. Entregar matriz: evidencia, hipotese, teste nao destrutivo, correcao proposta e rollback.

```sh
# Inventario read-only do ambiente
freebsd-version -kru
poudriere version
poudriere jail -l
poudriere ports -l
swapinfo -h
df -h
zpool list

# Inspecionar logs sem apagar dados
ls -lah /usr/local/poudriere/data/logs/bulk
```

Nao atribuir erro a RAM apenas porque o log termina com `Killed`; verificar kernel, swap e eventos. Nao recomendar alterar MAKE_JOBS_NUMBER como unica solucao sem validar a semantica do port.

## Entrega obrigatoria

Indicar ambiente confirmado, evidencias, comandos efetivamente executados, comandos apenas propostos, riscos, verificacoes, versao e rollback. Nunca declarar sucesso de operacao que nao foi executada.
