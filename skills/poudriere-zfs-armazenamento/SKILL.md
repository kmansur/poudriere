---
name: poudriere-zfs-armazenamento
description: Use em dataset cheio, Device busy, distfiles, snapshots, quotas ou limpeza de espaco.
---

# ZFS e capacidade

**Versao:** 1.0.0  
**Projeto:** Poudriere / FreeBSD  
**Acionamento:** Use em dataset cheio, Device busy, distfiles, snapshots, quotas ou limpeza de espaco.

## Politica

Siga `AGENTS.md`. Realize consultas sem alteracao antes de comandos mutaveis. Requer autorizacao expressa para alterar o host. Use `vi` para edicoes, mantenha comentarios em ASCII sem acentos nos arquivos de configuracao, incremente versoes e documente rollback.

## Procedimento


1. Observar primeiro a hierarquia e os mountpoints reais; nao assumir que BASEFS corresponde ao dataset.
2. Verificar pool, quotas, reservation, snapshots, volumes temporarios e processos que mantem mounts abertos.
3. Quantificar espaco recuperavel e custo de apagar caches, distfiles ou snapshots.
4. Nunca usar `zfs destroy -r`, `rm -rf` ou `poudriere pkgclean -y` sem inventario, alvo exato, impacto e aprovacao.
5. Para `Device busy`, inspecionar processos, jails e mounts ativos antes de qualquer tentativa de desmontagem.

```sh
# Inspecao nao destrutiva
zpool list
zpool status
zfs list -o name,used,avail,refer,mountpoint
zfs list -t snapshot -o name,used,creation
zfs get -r quota,refquota,reservation,mountpoint zroot/poudriere
mount
```

O caminho ZFS `zroot/poudriere` e exemplo da documentacao historica; validar a existencia antes de executar a consulta direcionada.

## Entrega obrigatoria

Indicar ambiente confirmado, evidencias, comandos efetivamente executados, comandos apenas propostos, riscos, verificacoes, versao e rollback. Nunca declarar sucesso de operacao que nao foi executada.
