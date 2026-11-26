# Technical Documentation: 
**Poudriere with FreeBSD 14.x/15.x Jails + NGINX + ccache**

**Version: 1.0 — Official Base of the Poudriere Net Tech Project**

---

## 1. Environment Overview

- **Hostname:** `pkg.domain.com.br`
- **Host System:** FreeBSD 14.3 with ZFS
- **Build Jail:** FreeBSD 14.3
- **Poudriere Base Storage:** `/usr/local/poudriere`

A virtual machine was created with the following specs:

- 8 GB RAM
- 4 CPUs
- 100 GB Disk

This server supports approximately 10 FreeBSD 14.3 servers and is prepared for FreeBSD 15.
The environment has about 1,000 ports installed, many with customized options.
Poudriere was chosen to manage, customize, and distribute these packages efficiently.

---

## 2. ZFS Preparation

> **Why:**  
> Separate ZFS datasets are created to organize Poudriere's components (jails, ports, builds, distfiles), improving performance, manageability, and backup flexibility.

```sh
zfs create zroot/poudriere
zfs create zroot/poudriere/ports
zfs create zroot/poudriere/jails
zfs create zroot/poudriere/data
zfs create zroot/poudriere/distfiles
zfs set mountpoint=/usr/local/poudriere zroot/poudriere
```

---

## 3. Install Required Packages

> Installs essential software: Poudriere for package building, NGINX to publish repositories, `git-lite` for fetching sources, and `ccache` for faster builds.

```sh
pkg install -y poudriere-devel nginx git-lite ccache
```

---

## 4. Configure `ccache`

> `ccache` caches compilation results, significantly speeding up repeated builds and reducing CPU usage.

### 4.1 Create and Configure Cache Directory

> Defines a dedicated location for cached compilation data, ensuring proper permissions and separation from system directories.

```sh
mkdir -p /var/cache/ccache
chown nobody:nobody /var/cache/ccache
chmod 755 /var/cache/ccache
```

### 4.2 Configure `/var/cache/ccache/ccache.conf`

> Sets `ccache` operational parameters (e.g., size limit, compression, performance optimizations).

```conf
cache_dir = /var/cache/ccache
base_dir = /var/cache/ccache
cache_dir_levels = 2
max_size = 20.0G
compression = true
compression_level = 6
hash_dir = false
sloppiness = time_macros,locale,pch_defines
```

### 4.3 Create Symlinks

> Ensures `ccache` can be accessed transparently by the build environment and the system tools.

```sh
mkdir /root/.ccache
ln -s /var/cache/ccache/ccache.conf /root/.ccache/ccache.conf
ln -s /var/cache/ccache/ccache.conf /usr/local/etc/ccache.conf
```

### 4.4 Validate `ccache` Functionality

> Verifies that `ccache` is correctly configured and operational.

```sh
ccache -s
```

### 4.5 Enable in the Jail's `/usr/local/etc/poudriere.d/make.conf`

> Forces all ports compiled inside the jail to automatically use `ccache`.

```make
WITH_CCACHE_BUILD=yes
CCACHE_DIR=/root/.ccache
```

---

## 5. Create Keys for Repository Signing

> Generates RSA keys to cryptographically sign the package repository, ensuring client-side authenticity and integrity verification.

```sh
mkdir -p /usr/local/etc/ssl/keys
mkdir -p /usr/local/etc/ssl/certs
chmod 0600 /usr/local/etc/ssl/keys
openssl genrsa -out /usr/local/etc/ssl/keys/poudriere.key 4096
openssl rsa -in /usr/local/etc/ssl/keys/poudriere.key -pubout -out /usr/local/etc/ssl/certs/poudriere.cert
```

---

## 6. Configure `/usr/local/etc/poudriere.conf`

> Defines the main Poudriere settings, such as dataset pool, mirrors, caching directories, and build behavior.

```conf
# Let poudriere use ports' MAKE_JOBS (parallel build inside make itself)
ALLOW_MAKE_JOBS=yes

# Base directory where poudriere stores everything (jails, ports, data, logs, etc.)
BASEFS=/usr/local/poudriere

# ccache directory used to speed up rebuilds
CCACHE_DIR=/var/cache/ccache

# If any port dependency changes, force a package rebuild
CHECK_CHANGED_DEPS=yes

# If build options change, show details and rebuild the package
CHECK_CHANGED_OPTIONS=verbose

# Cache for distfiles (tarballs fetched from ports)
DISTFILES_CACHE=${BASEFS}/distfiles

# Official server used to fetch FreeBSD base/jails
FREEBSD_HOST=https://download.FreeBSD.org

# Do not keep old packages in the repo after a successful build (remove old versions)
KEEP_OLD_PACKAGES=no

# Number of parallel poudriere jobs (how many ports at once)
PARALLEL_JOBS=5

# Private key used to sign the pkg repository
PKG_REPO_SIGNING_KEY=/usr/local/etc/ssl/keys/poudriere.key 

# Poudriere data directory (repos, jails, logs, etc.)
POUDRIERE_DATA=${BASEFS}/data

# resolv.conf file copied into jails (DNS used during builds)
RESOLV_CONF=/etc/resolv.conf

# Do not run portlint on ports (skip extra port quality checks)
USE_PORTLINT=no

# Use tmpfs for the build data area (faster, uses RAM)
USE_TMPFS="data" 

# TMPFS_BLACKLIST only matters when the work directories (wrkdir) are on
# tmpfs. With USE_TMPFS="data" they are not, so it is not needed. If you use
# USE_TMPFS=yes or "wrkdir data", list package names (not origins) and set
# the directory used instead of tmpfs, for example:
#   TMPFS_BLACKLIST="rust llvm*"
#   TMPFS_BLACKLIST_TMPDIR=${BASEFS}/data/cache/tmp

# ZFS pool used by poudriere for datasets (jails, data, etc.)
ZPOOL=zroot

# Max file descriptors (ulimit -n) inside builds. The Poudriere default is
# 8192; lower values break large builds (rust, node, llvm) with
# "Too many open files".
MAX_FILES=8192

# Update the repository in an atomic way (swap repo only when the new set is ready)
ATOMIC_PACKAGE_REPOSITORY=yes

# Branch of the binary repository used for fetch (for example latest instead of quarterly)
PACKAGE_FETCH_BRANCH=latest

# URL of the remote binary repository used to fetch some packages
PACKAGE_FETCH_URL=pkg+http://pkg.FreeBSD.org/\${ABI}

# List of packages allowed for binary fetch (toolchains and some heavy/important packages)
PACKAGE_FETCH_WHITELIST="rust llvm* gcc* cargo* tex* clamav"

# Heavy packages treated as mutually exclusive in builds (avoid building many toolchains at the same time)
MUTUALLY_EXCLUSIVE_BUILD_PACKAGES="llvm* rust* gcc*"

# Even if some ports fail, commit the successful packages and run the publish hook
COMMIT_PACKAGES_ON_FAILURE=yes

# Handle dependencies by name only, ignore version when resolving deps (reduce unnecessary rebuilds)
PKG_NO_VERSION_FOR_DEPS=yes
```

---

## 7. Configure `/usr/local/etc/poudriere.d/make.conf`

> Sets global build options, such as PHP version, disables graphical dependencies, enables `ccache`, and suppresses interactive prompts.

```make
DEFAULT_VERSIONS+= php=82
WITH_CCACHE_BUILD=yes
CCACHE_DIR=/root/.ccache
BATCH=yes
DISABLE_LICENSES=yes
NO_INTERACTION=yes
OPTIONS_UNSET+= X11
```

---

## 8. Configure and Start NGINX

> NGINX is used to serve the compiled packages and build logs via HTTP to clients or administrators.

```sh
sysrc nginx_enable=YES
```

Example `nginx.conf` and MIME adjustment included.

```sh
worker_processes  1;

events {
    worker_connections  1024;
}

http {
    include       mime.types;
    default_type  application/octet-stream;

    sendfile        on;
    keepalive_timeout  65;

    # Redirect all HTTP traffic to HTTPS
    server {
        listen 80;
        server_name pkg.domain.com.br;

        return 301 https://$host$request_uri;
    }

    # HTTPS Server
    server {
        listen       443 ssl;
        server_name  pkg.domain.com.br;

        # SSL Certificates
        ssl_certificate     /usr/local/etc/nginx/ssl/pkg.domain.com.br.pem;
        ssl_certificate_key /usr/local/etc/nginx/ssl/pkg.domain.com.br.key;

        ssl_protocols TLSv1.2 TLSv1.3;
        ssl_ciphers HIGH:!aNULL:!MD5;

        # Website root directory
        root /usr/local/share/poudriere/html;
        autoindex on;

        location /data {
                alias /usr/local/poudriere/data/logs/bulk;
                autoindex on;
        }

        location /packages {
                root /usr/local/poudriere/data;
                autoindex on;
        }

        # Custom error page
        error_page   500 502 503 504  /50x.html;
        location = /50x.html {
            root   /usr/local/www/nginx-dist;
        }
    }
}

```

Edit the file `/usr/local/etc/nginx/mime.types` and add the following line

```nginx
text/plain    log;
```
### 8.1. Create a directory for the SSL files (if it doesn’t already exist)

```shell
mkdir -p /usr/local/etc/nginx/ssl
```

### 8.2. Generate the self-signed certificate and private key

Replace pkg.domain.com.br with your actual domain name.

```shell
openssl req -x509 -nodes -days 365 \
  -newkey rsa:2048 \
  -keyout /usr/local/etc/nginx/ssl/pkg.domain.com.br.key \
  -out /usr/local/etc/nginx/ssl/pkg.domain.com.br.pem \
  -subj "/C=BR/ST=State/L=City/O=Organization/CN=pkg.domain.com.br"
```
### 8.3. Set appropriate permissions

``` shell
chmod 600 /usr/local/etc/nginx/ssl/pkg.domain.com.br.*
```

### 8.4. Test the NGINX configuration

```shell
nginx -t
```

### 8.5. Reload NGINX to apply the changes

```shell
service nginx reload
```

---

## 9. Create the Jail and Ports Tree

> The jail provides an isolated environment for package building; the ports tree provides the software source code structure.

```sh
poudriere jail -c -j 14-3-RELEASE-amd64 -v 14.3-RELEASE
poudriere ports -c -p default
```

---

## 10. Update the Jail and Ports Periodically

> Keeps the jail environment and the ports collection updated with the latest security patches and software versions.

```sh
poudriere jail -u -j 14-3-RELEASE-amd64
poudriere ports -u -p default
```

---

## 11. Create the Package List

> Defines which ports should be built automatically, improving build control and avoiding manual selections.
> Create the file /usr/local/etc/poudriere.d/14-3-RELEASE-amd64-pkglist with the desired ports:

```
ports-mgmt/pkg
www/nginx
sysutils/tmux
```
---

## 12. Manual Build

> Manually triggers a bulk build to generate the package repository based on the jail and the selected ports tree.

```sh
poudriere bulk -j 14-3-RELEASE-amd64 -p default -f /usr/local/etc/poudriere.d/14-3-RELEASE-amd64-pkglist
```
---

## 13. Install the build script and automate with cron

### 13.1. Install the script from Git

> A Git checkout makes updates and rollbacks simple (`git pull`, `git checkout v1.18`). Since 1.19 the script does not update itself (AUTOUPDATE is ignored).

```sh
pkg install -y git-lite
git clone https://github.com/kmansur/poudriere /usr/local/src/poudriere
mkdir -p /usr/local/scripts
install -m 0755 /usr/local/src/poudriere/scripts/poudriere_build.sh /usr/local/scripts/
# Create the configuration only if it does not exist yet, then edit it
test -e /usr/local/scripts/poudriere_build.cfg || \
    install -m 0640 /usr/local/src/poudriere/scripts/poudriere_build.cfg.sample /usr/local/scripts/poudriere_build.cfg
vi /usr/local/scripts/poudriere_build.cfg
```

Main settings in `poudriere_build.cfg` (see the sample for all of them):

| Variable | Default | Use |
|---|---|---|
| `EMAIL_RECIPIENT` | (required) | Report recipient |
| `JAIL_NAME` | `systembase` | One jail, or several separated by spaces, built one after the other in the same run (the ports tree is updated once). `jail:pkglist` uses another list for that jail, e.g. `"14-3-RELEASE-amd64 15-0-RELEASE-amd64:15-pkglist"` |
| `PKGLIST_NAME` | `pkglist` | List in `/usr/local/etc/poudriere.d/` |
| `PORTS_TREE` | `default` | Ports tree; one lock per tree |
| `UPDATE_PORTS_TREE` | `yes` | `no` keeps the tree as is |
| `MOVED_ACTION` | `report` | Origins renamed/removed in the tree `MOVED` file: `report` lists them in the mail, `fix` also rewrites the list (with `.bak`) and copies saved options |
| `LOG_RETENTION_DAYS` | `7` | Script logs kept |

Test once by hand and check the mail and the exit status:

```sh
/usr/local/scripts/poudriere_build.sh; echo "exit: $?"
```

To update later:

```sh
cd /usr/local/src/poudriere && git pull
install -m 0755 scripts/poudriere_build.sh /usr/local/scripts/
```

### 13.2. Automate with cron

> One entry builds every jail listed in `JAIL_NAME`. A run that finds the previous one still working is skipped and logged to syslog, so an hourly schedule is safe.

```cron
0 * * * * /usr/local/scripts/poudriere_build.sh
```

Check that no jail is left out: `poudriere jail -l` should list only jails present in `JAIL_NAME` (or in another cron entry).

---

## 14. Access the Repository via Browser

> Allows users and clients to browse available packages and logs through a standard web browser.

```
https://pkg.domain.com.br/
```
---

## 15. Configure Client-Side Repository and Signing

> Ensures clients trust the package repository by verifying signatures using the public key.

### 15.1. Copy the public key to the client

```sh
scp /usr/local/etc/ssl/certs/poudriere.cert user@client:/usr/local/etc/ssl/certs/
```

### 15.2. Configure the repository on the client

Create or edit the file `/usr/local/etc/pkg/repos/poudriere.conf` with the following content:

```conf
poudriere: {
  url: "https://pkg.domain.com.br/packages/14-3-RELEASE-amd64-default",
  mirror_type: "http",
  signature_type: "pubkey",
  pubkey: "/usr/local/etc/ssl/certs/poudriere.cert",
  enabled: yes
}
```

### 15.3. Trust the server certificate (self-signed only)

`pkg` verifies the HTTPS certificate. With the self-signed certificate from section 8.2, `pkg update` fails with a certificate error unless the client trusts it. Choose one:

- **Recommended:** use a certificate from a public CA (for example Let's Encrypt with `security/py-certbot` or `security/acme.sh`). Clients need nothing else.
- **Self-signed / internal CA:** copy the server certificate to each client and point `pkg` at it:

```sh
# On the client
scp root@pkg.domain.com.br:/usr/local/etc/nginx/ssl/pkg.domain.com.br.pem /usr/local/etc/ssl/certs/pkg-server.pem
vi /usr/local/etc/pkg.conf
```

```conf
PKG_ENV {
  SSL_CA_CERT_FILE: "/usr/local/etc/ssl/certs/pkg-server.pem"
}
```

The certificate must have been generated with the host name used in the repository URL (`CN`/`subjectAltName`), and it must be copied again when it is renewed (the sample is valid for 365 days).

### 15.4. Test

```sh
pkg update -f
```
> The client should accept the signature and update successfully. Otherwise, it will return an error indicating an invalid signature.
---

## 16. Useful Additional Commands

> Provides extra administration tools for updating, checking builds, cleaning, and troubleshooting Poudriere environments.

### 16.1 Manually update the ports tree

```sh
poudriere ports -u -p default
```

### 16.2 Verify if the ports tree was downloaded correctly

```sh
poudriere ports -l
```

### 16.3 Rebuild only a specific package

```sh
poudriere bulk -j 14-3-RELEASE-amd64 print/texlive-texmf
```

### 16.4 Configure or change build options for a port

```sh
poudriere options -c -j 14-3-RELEASE-amd64 print/texlive-texmf
```

### 16.5 Build using a list of packages

```sh
poudriere bulk -j 14-3-RELEASE-amd64 -f /usr/local/etc/poudriere.d/14-3-RELEASE-amd64-pkglist
```

### 16.6 View logs from the latest builds

```sh
# List recent builds
poudriere status -j 14-3-RELEASE-amd64

# View errors from the latest build
less /usr/local/poudriere/data/logs/bulk/14-3-RELEASE-amd64-default/latest/logs/errors/*
```

### 16.7 Remove an existing jail

```sh
poudriere jail -d -j 14-3-RELEASE-amd64
```

### 16.8 Remove a ports tree

```sh
poudriere ports -d -p default
```

### 16.9 Check for orphaned (unused) packages

```sh
poudriere pkgclean -j 14-3-RELEASE-amd64 -p default -n
```

### 16.10 Check saved options for a specific port

```sh
poudriere options -j 14-3-RELEASE-amd64 -p default -s print/texlive-texmf
```

---

# ✅ Ready!
