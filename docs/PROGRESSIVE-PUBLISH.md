# Publicacao progressiva - 1.19.0-beta.2

## Estado experimental

A branch nao altera o Poudriere instalado, sua configuracao, jails ou URL de producao. O script principal continua com lista unica. O plugin usa eventos confirmados em common.sh da versao instalada; retorna zero mesmo em falha. O worker e independente, executado por cron a cada cinco minutos. Configuracao desabilitada por padrao. A beta bloqueia AUTOUPDATE mesmo se o cfg antigo estiver habilitado: o atualizador de arquivo unico nao e adequado a um conjunto de scripts.

## Limites de seguranca e homologacao

- Python 3.11+ e necessario para JSON, hashes e verificacao de manifestos. Shell permanece /bin/sh.
- O worker cria hard links dos pacotes nativos para objetos privados identificados por SHA256 (o Poudriere nunca reescreve um pacote no lugar; o proprio .building e um clone por hard links). Se state_root estiver em outro sistema de arquivos/dataset, o worker copia o arquivo e verifica o hash antes e depois. Manter state_root no mesmo dataset dos packages para nao duplicar o repositorio. O limite de min_free_gib nao reserva espaco e nao impede outros processos de consumir o pool.
- Indice de hashes (state_root/MASTER/index.json, por inode, tamanho e mtime) e cache de manifestos (manifests/SHA256.json): pacotes inalterados nao sao lidos de novo a cada execucao. Apagar index.json forca um novo calculo completo, sem outro efeito.
- Retencao habilitada por padrao (bloco retention do JSON): mantem a geracao current, as keep_generations mais novas e qualquer geracao com menos de min_age_hours; remove objetos nao referenciados por nenhuma geracao (apos 1 hora), manifestos orfaos, temporarios antigos e filas de eventos com mais de event_days, nunca a da build ativa. Clientes de laboratorio fixados em uma geracao removida deixam de funcionar: aponte-os para uma geracao recente ou aumente keep_generations/min_age_hours. Para nao apagar nada, usar "enabled": false.
- O worker usa .building/.buildname e eventos pkgbuild success. Confirmar que esse marcador existe durante a build na versao instalada e que PKG_EXT e .pkg. Se nao existir, apenas a geracao nativa sera publicada. Pacotes baixados por fetch sem hook de sucesso so entram na sincronizacao final.
- A selecao exige mesma ABI, origin igual e disponibilidade de shlibs, incluindo dependencias reversas. Quando o manifesto registra a versao da dependencia, ela precisa ser exata; dependencias sem versao (PKG_NO_VERSION_FOR_DEPS=yes, configuracao do INSTALL.md) sao aceitas por nome e origin, e a compatibilidade binaria fica a cargo da verificacao de shlibs. Dependencias externas previamente observadas sao toleradas por nome de pacote. Nao equivale ao solver pkg, nao prova compatibilidade binaria, conflitos de arquivos ou disponibilidade de bibliotecas base. Em caso de violacao falha fechada; nao desabilitar as verificacoes para contornar.
- O catalogo e gerado com pkg repo e RSA; a verificacao real de assinatura e solver em FreeBSD e obrigatoria antes de qualquer uso. Nao ha garantia de publicacao imediata de todo pacote.
- Usar somente URL de geracao imutavel em clientes de teste. Nao expor a raiz state_root, current, objects ou events via Nginx. Nao mudar /packages em producao. Uma URL estavel exige resolver a corrida entre catalogo e arquivos em geracoes diferentes, validacao do solver e politica de retencao.
- O worker usa flock exclusivo por master; os hooks nao dependem do lock. Nao ha alteracao de .latest nativo.
- Nao instalar durante builds ativos. Nao executar em producao antes de homologar.

## Instalacao de laboratorio (root, checkout fixado da branch)

Confira git status, git log -1, python3 --version, pkg help repo, espaco e ausencia de builds ativos. Nao instalar por cima de /usr/local/scripts/poudriere_build.sh.

```sh
# Validate shell scripts and run isolated unit tests
for f in scripts/poudriere_build.sh scripts/poudriere_publish.sh hooks/*.sh; do
    /bin/sh -n "$f" || exit 1
done
python3 tests/test_publish.py
sh tests/test_build.sh

# Create isolated beta directory and native plugin directory
install -d -m 0755 /usr/local/scripts/poudriere-beta
install -d -m 0755 /usr/local/etc/poudriere.d/hooks/plugins/progressive-publish
install -m 0755 scripts/poudriere_publish.sh scripts/poudriere_publish.py /usr/local/scripts/poudriere-beta/
install -m 0755 hooks/*.sh /usr/local/etc/poudriere.d/hooks/plugins/progressive-publish/

# Install only if no existing configuration
test ! -e /usr/local/etc/poudriere-progressive.json && \
    install -m 0600 scripts/poudriere-progressive.json.sample /usr/local/etc/poudriere-progressive.json

# Edit explicitly; keep enabled=false until a laboratory test is authorized
vi /usr/local/etc/poudriere-progressive.json
```

Enable only one test master. Run /usr/local/scripts/poudriere-beta/poudriere_publish.sh manually, inspect the output and the catalogue. For periodic runs after validation, use root crontab -e with EDITOR=vi and an entry such as:

```cron
*/5 * * * * /usr/local/scripts/poudriere-beta/poudriere_publish.sh >> /var/log/poudriere-progressive.log 2>&1
```

Before adding the cron entry verify no duplicate exists. Configure log rotation separately. Use the existing build script v1.18 for the first lab test; hooks work independently. The beta build wrapper is available for separate tests, with its own copied cfg and no automatic replacement of the stable script.

## Nginx laboratory example

Expose only immutable generation directories for a selected test master, not the parent directory. Substitute MASTER and GENERATION with verified values. Prefer a separate restricted virtual host or access control. Do not change the native location /packages. Use vi and backup before edits, nginx -t before reload.

```nginx
location /packages-progressive-test/ {
    alias /usr/local/poudriere/data/progressive/MASTER/generations/GENERATION/;
    autoindex off;
    # Restrict to an authorized test client/network before enabling.
    deny all;
}
```

Change the access rule only in the lab, then test pkg update, pkg upgrade -n and installation in disposable jails using a dedicated repository config with existing public key, native repositories disabled in that test only. Confirm catalog hash and all downloads, including a library rebuild and reverse dependencies. Test disk limit, corrupt archives, concurrent worker, hook failure, interrupted build, native final publication and rollback.

## Rollback

Set enabled=false with vi, remove only the beta cron entry using crontab -e, wait for the worker to exit, remove the test Nginx location after configtest and reload. Disable plugin by moving it outside hooks/plugins (do not just rename within plugins). Preserve state for forensic review; do not delete automatically. The native Poudriere and v1.18 remain unchanged. In lab clients restore their original repository config and run pkg update -f. A metadata rollback alone cannot downgrade installed packages.

Retention: to stop any automatic deletion set "retention": {"enabled": false} with vi; nothing already removed comes back, so raise keep_generations/min_age_hours before tests that pin a generation.

Build script 1.19.0-beta.2: the lock is now per ports tree in /var/run (was per jail in /tmp), so two jails sharing a tree do not run at the same time; the second run logs to syslog and exits 0. To roll back, reinstall the previous script from its Git tag or the main branch over the beta copy, keeping the existing poudriere_build.cfg.

## Validation status

Unit tests are provided (tests/test_publish.py, tests/test_build.sh), including an end-to-end worker run with a fake pkg(8); real FreeBSD/pkg signature, solver, hook timing and Nginx tests remain required. No production installation is authorized by this commit.
