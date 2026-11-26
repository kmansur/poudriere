---
name: poudriere-build
description: Use quando compilar um port, grupo de ports ou lista completa, inclusive rebuild seletivo.
---

# Operacao de builds

**Versao:** 1.0.0  
**Projeto:** Poudriere / FreeBSD  
**Acionamento:** Use quando compilar um port, grupo de ports ou lista completa, inclusive rebuild seletivo.

## Politica

Siga `AGENTS.md`. Realize consultas sem alteracao antes de comandos mutaveis. Requer autorizacao expressa para alterar o host. Use `vi` para edicoes, mantenha comentarios em ASCII sem acentos nos arquivos de configuracao, incremente versoes e documente rollback.

## Procedimento


1. Obter nome exato da jail e ports tree da saida de `poudriere jail -l` e `poudriere ports -l`.
2. Verificar se ha bulk concorrente, espaco livre, mem/swap e origem do pacote.
3. Antes de executar, mostrar impacto sobre fila, dependencia, logs e repositorio.
4. Se autorizado, compilar `category/port` ou `-f` com a lista existente; nao dividir lista grande sem pedido.
5. Verificar exit code, logs nativos, repositorio publicado e possiveis pacotes ignorados.

```sh
# Referencias, nao executar sem autorizacao
poudriere bulk -j 14-4-RELEASE-amd64 -p default graphics/png
poudriere bulk -j 14-4-RELEASE-amd64 -p default -f /usr/local/etc/poudriere.d/14-4-RELEASE-amd64-pkglist
```

Os nomes da jail e do arquivo acima sao exemplos historicos. A publicacao progressiva durante bulk e um requisito em estudo, nao um recurso confirmado do script v1.18. Nao criar solucao baseada em editar metadados assinados enquanto bulk esta em execucao.

## Entrega obrigatoria

Indicar ambiente confirmado, evidencias, comandos efetivamente executados, comandos apenas propostos, riscos, verificacoes, versao e rollback. Nunca declarar sucesso de operacao que nao foi executada.
