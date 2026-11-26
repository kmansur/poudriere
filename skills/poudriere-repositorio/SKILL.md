---
name: poudriere-repositorio
description: Use para Nginx, pkg repo, assinatura RSA, URL de distribuicao ou publicacao progressiva.
---

# Repositorio assinado e distribuicao

**Versao:** 1.0.0  
**Projeto:** Poudriere / FreeBSD  
**Acionamento:** Use para Nginx, pkg repo, assinatura RSA, URL de distribuicao ou publicacao progressiva.

## Politica

Siga `AGENTS.md`. Realize consultas sem alteracao antes de comandos mutaveis. Requer autorizacao expressa para alterar o host. Use `vi` para edicoes, mantenha comentarios em ASCII sem acentos nos arquivos de configuracao, incremente versoes e documente rollback.

## Procedimento


1. Conferir `PKG_REPO_SIGNING_KEY`, acesso a chave publica, permissions, URL, arquitetura e release do cliente.
2. Conferir configuracao real do Nginx, alias/root, logs de acesso e parametros de repositorio.
3. Verificar metadados e assinaturas; jamais alterar a chave privada ou copiar seu conteudo em logs/commits.
4. Preservar `ATOMIC_PACKAGE_REPOSITORY` se configurado e evitar disponibilizar indice incompleto.
5. Investigar mecanismo de publicacao incremental com staging, assinatura e troca atomica apenas em ambiente de teste; nao afirmar que a flag `bulk` resolve o requisito.

```sh
# Validacao sem alteracao
service nginx configtest
pkg -vv
ls -lah /usr/local/poudriere/data/packages
```

Na configuracao de cliente, nao habilitar simultaneamente repositorios oficiais conflitantes sem avaliar prioridades e proveniencia. Nunca assumir que o endpoint historico por HTTP/HTTPS corresponde ao endpoint atual.

## Entrega obrigatoria

Indicar ambiente confirmado, evidencias, comandos efetivamente executados, comandos apenas propostos, riscos, verificacoes, versao e rollback. Nunca declarar sucesso de operacao que nao foi executada.

## Publicacao progressiva (experimental, 1.19.0)

Consultar docs/PROGRESSIVE-PUBLISH.md. Usar somente geracoes imutaveis em laboratorio; nunca apontar clientes de producao ao publicador experimental. A validacao conservadora de manifestos nao substitui o solver do pkg. Nao alterar .latest nativo.
