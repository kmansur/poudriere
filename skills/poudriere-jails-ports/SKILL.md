---
name: poudriere-jails-ports
description: Use para listar, comparar, criar, atualizar ou investigar jails e arvore de ports.
---

# Gerenciamento de jails e ports

**Versao:** 1.0.0  
**Projeto:** Poudriere / FreeBSD  
**Acionamento:** Use para listar, comparar, criar, atualizar ou investigar jails e arvore de ports.

## Politica

Siga `AGENTS.md`. Realize consultas sem alteracao antes de comandos mutaveis. Requer autorizacao expressa para alterar o host. Use `vi` para edicoes, mantenha comentarios em ASCII sem acentos nos arquivos de configuracao, incremente versoes e documente rollback.

## Procedimento


1. Identificar releases efetivos e arvore utilizada; distinguir host da jail.
2. Registrar estado antes e depois, inclusive patchlevel e origem da arvore.
3. Alertar que atualizacoes mudam entradas de build e podem causar muitos rebuilds.
4. Pedir aprovacao para atualizar; validar conclusao e exit code.

```sh
# Comandos de consulta sem alteracao
poudriere jail -l
poudriere ports -l
freebsd-version -kru

# Comandos mutaveis somente apos aprovacao
poudriere jail -u -j 14-4-RELEASE-amd64
poudriere ports -u -p default
```

Nao confundir atualizar uma jail com atualizar o host. Nao presumir suporte a releases antigos; verificar politica de suporte e repositorios atualmente disponiveis.

## Entrega obrigatoria

Indicar ambiente confirmado, evidencias, comandos efetivamente executados, comandos apenas propostos, riscos, verificacoes, versao e rollback. Nunca declarar sucesso de operacao que nao foi executada.
