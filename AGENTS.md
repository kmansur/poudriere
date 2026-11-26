# AGENTS.md - Projeto Poudriere

**Versao:** 1.1.0  
**Data:** 2026-11-26  
**Escopo:** automacao, compilacao, publicacao e manutencao de pacotes FreeBSD com Poudriere.

## 1. Objetivo

Manter um repositorio proprio de pacotes FreeBSD compilados com opcoes personalizadas, com Poudriere, ZFS, ccache e distribuicao por Nginx. Preservar a operacao existente e aumentar confiabilidade, rastreabilidade e recuperacao diante de falhas.

## 2. Fontes e hierarquia

1. Estado observado na maquina, saidas de comandos, logs e configuracoes efetivas.
2. Arquivos atuais do repositorio e suas versoes sob Git.
3. `poudriere_build.sh` v1.18, `poudriere_build.cfg.sample`, `make.conf` e `Poudriere-devel.md` disponibilizados como base nesta revisao.
4. Historico do projeto, usado como contexto, nao como prova do estado atual.
5. Documentacao oficial do FreeBSD/Poudriere, verificando a versao instalada antes de sugerir flags.

Em caso de divergencia, informar o conflito. Nao tratar um exemplo historico como configuracao de producao. Nao presumir que funcionalidades solicitadas anteriormente ja foram implementadas.

## 3. Ambiente conhecido e limites

- Sistema operacional: FreeBSD em ingles (USA), host com ZFS.
- Jails utilizadas no projeto: series FreeBSD 14 e 15; nomes variam conforme instalacao.
- Arvore de ports historicamente denominada `default`.
- Diretorio-base documentado: `/usr/local/poudriere`.
- Log do script: `/var/log/poudriere`.
- Logs nativos do bulk: verificar em `/usr/local/poudriere/data/logs/bulk` ou no diretorio configurado.
- Lista de ports: `/usr/local/etc/poudriere.d/<nome_da_lista>`.
- Opcoes de ports: verificar os diretorios reais de `/usr/local/etc/poudriere.d`, sem assumir convencoes nao confirmadas.
- Script: `poudriere_build.sh` v1.18 no material de referencia.
- A lista de producao ja foi descrita com mais de mil ports; nao dividi-la por padrao.
- O host atual, as jails existentes, o pool ZFS, a versao do Poudriere, as chaves e URLs do repositorio devem ser confirmados a cada intervencao.

## 4. Regras obrigatorias para agentes

1. Responder e documentar em portugues do Brasil.
2. Usar `vi` em todos os procedimentos manuais de edicao. Nao orientar `nano`, `sed -i` ou troca silenciosa de arquivos.
3. Scripts devem ser POSIX `/bin/sh` compativeis com FreeBSD, salvo requisito expresso diferente.
4. Em scripts e arquivos de configuracao, usar comentarios detalhados em ASCII, sem acentos; mensagens tecnicas podem seguir a mesma convencao.
5. Toda alteracao, adicao ou remocao exige registro de versao, changelog, motivo, impacto, teste e rollback. Usar SemVer quando aplicavel.
6. Antes de alterar arquivos, gerar backup datado e preservar permissoes e proprietarios.
7. Nao executar alteracoes em host remoto, reiniciar servicos, apagar dados, limpar packages, atualizar jails ou publicar pacotes sem autorizacao explicita.
8. Usar primeiro inspecao read-only: `freebsd-version`, `poudriere version`, `poudriere jail -l`, `poudriere ports -l`, `zpool list`, `zfs list`, `df -h`, `pkg -v`, `git status`.
9. Exibir comandos separadamente em fases: coleta, avaliacao, alteracao, validacao e rollback.
10. Nao incluir segredos, chaves privadas, senhas, tokens, emails reais ou configuracoes sigilosas no repositorio.
11. Nao usar caminhos supostos como destino de exclusao. Resolver mountpoints com `zfs get mountpoint` e configuracoes reais.
12. Nao inventar mensagens de log, resultados de testes, suporte a flags ou recursos do Poudriere.
13. Em erro de build, investigar a primeira falha causal e nao apenas o final do log.
14. Preservar assinatura do repositorio, integridade de metadados e publicacao atomica.
15. Propor primeiro mudancas pequenas e reversiveis, com diffs e testes sem efeito colateral.

## 5. Fluxo padrao de trabalho

### Fase A - Inventario

- Identificar host, release, release da jail, versao do Poudriere, pool ZFS, tree de ports e configuracoes efetivas.
- Inspecionar script, cfg, make.conf, options, pkglist, logs e estado Git.
- Determinar se uma build ou limpeza ja esta ativa e quais recursos estao livres.

### Fase B - Diagnostico

- Definir sintoma, hora, jail, origin do port e log relevante.
- Correlacionar mensagens de erro com memoria, swap, disco, quota, processos, rede, dependencias, compilador e flags.
- Distinguir falha de port, falha de host, falha do script, falha de publicacao e falha de integridade do repositorio.

### Fase C - Proposta

- Apresentar causa confirmada ou hipotese, impacto, comandos, backup, versao seguinte, plano de teste e rollback.
- Solicitar aprovacao antes de qualquer operacao mutavel.

### Fase D - Implementacao autorizada

- Criar branch e backup; alterar com `vi`; registrar changelog; executar validacao estatica; testar isoladamente.
- Nao substituir o script em producao por download automatico sem verificacao de origem e integridade.

### Fase E - Validacao

- Testar `/bin/sh -n` para shell, `nginx -t`/`service nginx configtest` quando pertinente e verificar status de build, repositorio e assinatura.
- Exigir evidencia verificavel, rollback funcional e resumo das diferencas.

## 6. Riscos ja identificados na base v1.18

- `AUTOUPDATE=yes` baixa do GitHub e substitui o proprio script; necessita controle de versao, verificacao de integridade e mecanismo de rollback.
- `poudriere jail -u` e `poudriere ports -u` nao possuem verificacao individual de retorno antes de iniciar `bulk`.
- O script executa `pkgclean -y` apos a tentativa de build, inclusive quando ha falha; isso exige politica conservadora.
- O `find` remove logs do script por retencao, mas nao significa retencao equivalente dos logs nativos Poudriere.
- A invocacao de `mail` deve ser revista e testada; nao assumir entrega bem-sucedida.
- `poudriere_build.cfg.sample` contem `LOG_RETENTION_DAYS=7` sem quebra de linha final; normalizar na proxima revisao.
- A opcao `-b latest` deve ser validada na versao instalada e considerada no contexto da politica de pacotes locais.
- Publicacao progressiva de pacotes nao foi comprovada pela implementacao v1.18; estudar sem comprometer atomicidade ou assinaturas.
- A descricao historica de Nginx e de SSL contem valores de exemplo que precisam de verificacao contra a instalacao efetiva.

## 7. Skills e acionamento

| Skill | Quando usar |
| --- | --- |
| `poudriere-diagnostico` | Falha em logs, erros de Rust/Node/mesa, processos e recursos |
| `poudriere-build` | Compilar um port, um conjunto ou a lista integral |
| `poudriere-jails-ports` | Criar/listar/atualizar jails e arvore ports |
| `poudriere-zfs-armazenamento` | Capacidade, snapshots, datasets, disco cheio, Device busy |
| `poudriere-repositorio` | Assinatura, Nginx, pkg e publicacao de pacotes |
| `poudriere-configuracao` | make.conf, options, cfg e politica de parametros |
| `poudriere-script-manutencao` | Evolucao versionada do script e testes |
| `poudriere-incidentes` | Triagem e recuperacao conservadora em producao |

Consultar `skills/<nome>/SKILL.md` conforme a tarefa. Ler somente as skills relevantes, sem executar automaticamente seus comandos.

## 8. Criterios de aceite de qualquer mudanca

- Evidencia da causa e escopo definido.
- Diff revisavel, versao incrementada e changelog atualizado.
- Backup e rollback documentados.
- Testes estaticos e teste funcional proporcionais ao risco.
- Sem regressao em jails 14 e 15 ou na assinatura dos repositorios.
- Sem perda de packages, metadados, logs importantes ou alteracao silenciosa de opcoes.
- Resultado final diferencia claramente: feito, testado, proposto e pendente.

## 9. Referencias e estado da documentacao

- `Poudriere-devel.md` descreve originalmente host e jail 14.2 e deve ser tratado como historico.
- `make.conf` anexo contem PHP 8.2, ccache, modo batch e `OPTIONS_UNSET+= X11`, nao necessariamente as opcoes atualmente ativas no host.
- `poudriere_build.cfg.sample` e `poudriere_build.sh` sao a linha de base v1.18 desta revisao.
- Nao alterar os arquivos de origem durante a geracao deste conjunto de instrucoes.

## 10. Beta de publicacao progressiva

A branch feature/progressive-publish contem 1.19.0-beta.2. Consultar docs/PROGRESSIVE-PUBLISH.md. Nunca ativar a beta em producao sem homologacao. Nao modificar arquivos nativos do Poudriere. O atualizador de arquivo unico fica bloqueado na beta.
