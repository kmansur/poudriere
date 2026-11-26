---
name: poudriere-configuracao
description: Use para make.conf, variaveis da build, flags de ports, configuracao externa e ccache.
---

# Configuracao de builds e opcoes

**Versao:** 1.0.0  
**Projeto:** Poudriere / FreeBSD  
**Acionamento:** Use para make.conf, variaveis da build, flags de ports, configuracao externa e ccache.

## Politica

Siga `AGENTS.md`. Realize consultas sem alteracao antes de comandos mutaveis. Requer autorizacao expressa para alterar o host. Use `vi` para edicoes, mantenha comentarios em ASCII sem acentos nos arquivos de configuracao, incremente versoes e documente rollback.

## Procedimento


1. Localizar os arquivos realmente ativos e comparar com `make.conf` e `poudriere_build.cfg.sample` da base.
2. Verificar escopo: global, jail, tree, set ou port especifico; nao sobrescrever configuracao sem identificar precedencia.
3. Para options de um port, informar comando e risco de recompilacao de dependencias.
4. Editar usando `vi` e comentarios ASCII detalhados. Backup datado e diff obrigatorios.
5. Validar sintaxe e impacto antes de iniciar bulk.

```sh
# Inspecao de configuracoes
ls -lah /usr/local/etc/poudriere.d
cat /usr/local/etc/poudriere.d/make.conf
ccache -s

# Ajuste interativo de um port, somente apos aprovacao
poudriere options -c -j 14-4-RELEASE-amd64 -p default ftp/curl
```

`poudriere options` exige um ou mais ports; executar sem argumento de pacote nao lista todas as configuracoes. Nao assumir que o subdiretorio options e nomeado apenas pela jail.

## Entrega obrigatoria

Indicar ambiente confirmado, evidencias, comandos efetivamente executados, comandos apenas propostos, riscos, verificacoes, versao e rollback. Nunca declarar sucesso de operacao que nao foi executada.
