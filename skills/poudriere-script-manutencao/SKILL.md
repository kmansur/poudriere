---
name: poudriere-script-manutencao
description: Use quando refatorar `poudriere_build.sh`, corrigir bugs, implementar novos requisitos ou alterar cfg.
---

# Manutencao versionada do script

**Versao:** 1.0.0  
**Projeto:** Poudriere / FreeBSD  
**Acionamento:** Use quando refatorar `poudriere_build.sh`, corrigir bugs, implementar novos requisitos ou alterar cfg.

## Politica

Siga `AGENTS.md`. Realize consultas sem alteracao antes de comandos mutaveis. Requer autorizacao expressa para alterar o host. Use `vi` para edicoes, mantenha comentarios em ASCII sem acentos nos arquivos de configuracao, incremente versoes e documente rollback.

## Procedimento


1. Abrir linha de base, registro de versao e cfg real sem expor informacoes sigilosas.
2. Descrever requisito, comportamento atual, riscos, contrato CLI, compatibilidade FreeBSD e casos de teste.
3. Priorizar: verificacao de retornos de jail/ports, propagacao correta de falha, protecao de limpeza, emails testaveis e mecanismo de update verificado.
4. Preservar CLI `-j`, `-p`, `-l`, `-h` e execucao via lockf; testar precedencia cfg x CLI e reinicio por auto-update.
5. Alterar com `vi`; incrementar versao, atualizar CHANGELOG, produzir diff e rollback.
6. Usar `/bin/sh -n`, `shellcheck` se instalado e testes com mocks de poudriere, fetch, mail, lockf e find antes de teste real.

```sh
# Validacao estatica read-only
/bin/sh -n ./poudriere_build.sh
git diff --check
git status --short
```

Incluir testes para falha no download, espaco insuficiente, lock concorrente, cfg ausente, build falhando, mail ausente e limpeza bloqueada. Nao dizer que auto-update da v1.18 possui validacao criptografica ou rollback automatico.

## Entrega obrigatoria

Indicar ambiente confirmado, evidencias, comandos efetivamente executados, comandos apenas propostos, riscos, verificacoes, versao e rollback. Nunca declarar sucesso de operacao que nao foi executada.
