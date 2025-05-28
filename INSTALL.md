# Technical Documentation: 
**Poudriere with FreeBSD 15.0-CURRENT Jail + NGINX + ccache**

**Version: 1.0 — Official Base of the Poudriere Net Tech Project**

---

## 1. Environment Overview

- **Hostname:** `pkg.domain.com.br`
- **Host System:** FreeBSD 15 with ZFS
- **Build Jail:** FreeBSD 14.2
- **Poudriere Base Storage:** `/usr/local/poudriere`

A virtual machine was created with the following specs:

- 8 GB RAM
- 4 CPUs
- 100 GB Disk

This server supports approximately 10 FreeBSD 14.2 servers and is prepared for FreeBSD 15.
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
mkdir -p /usr/local/etc/ssl/{keys,certs}
chmod 0600 /usr/local/etc/ssl/keys
openssl genrsa -out /usr/local/etc/ssl/keys/poudriere.key 4096
openssl rsa -in /usr/local/etc/ssl/keys/poudriere.key -pubout -out /usr/local/etc/ssl/certs/poudriere.cert
```

---

## 6. Configure `/usr/local/etc/poudriere.conf`

> Defines the main Poudriere settings, such as dataset pool, mirrors, caching directories, and build behavior.

```conf
ZPOOL=zroot
BASEFS=/usr/local/poudriere
POUDRIERE_DATA=${BASEFS}/data
FREEBSD_HOST=https://download.FreeBSD.org
RESOLV_CONF=/etc/resolv.conf
DISTFILES_CACHE=${BASEFS}/distfiles
CHECK_CHANGED_OPTIONS=verbose
CHECK_CHANGED_DEPS=yes
PKG_REPO_SIGNING_KEY=/usr/local/etc/ssl/keys/poudriere.key
CCACHE_DIR=/var/cache/ccache
PARALLEL_JOBS=3
ALLOW_MAKE_JOBS=yes
ATOMIC_PACKAGE_REPOSITORY=yes
PACKAGE_FETCH_BRANCH=latest
PACKAGE_FETCH_URL=pkg+http://pkg.FreeBSD.org/${ABI}
PACKAGE_FETCH_WHITELIST="rust llvm* gcc* cargo*"
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

Edit the file `/usr/local/etc/nginx/mime.types` and add the following line:

```nginx
text/plain    log;
```
### 8.1. Create a directory for the SSL files (if it doesn’t already exist):

```shell
mkdir -p /usr/local/etc/nginx/ssl
```

### 8.2. Generate the self-signed certificate and private key:

Replace pkg.domain.com.br with your actual domain name.

```shell
openssl req -x509 -nodes -days 365 \
  -newkey rsa:2048 \
  -keyout /usr/local/etc/nginx/ssl/pkg.domain.com.br.key \
  -out /usr/local/etc/nginx/ssl/pkg.domain.com.br.pem \
  -subj "/C=BR/ST=State/L=City/O=Organization/CN=pkg.domain.com.br"
```
### 8.3. Set appropriate permissions:

``` shell
chmod 600 /usr/local/etc/nginx/ssl/pkg.domain.com.br.*
```

### 8.4. Test the NGINX configuration:

```shell
nginx -t
```

### 8.5. Reload NGINX to apply the changes:

```shell
service nginx reload
```

---

## 9. Create the Jail and Ports Tree

> The jail provides an isolated environment for package building; the ports tree provides the software source code structure.

```sh
poudriere jail -c -j 14-2-RELEASE-amd64 -v 14.2-RELEASE
poudriere ports -c -p default
```

---

## 10. Update the Jail and Ports Periodically

> Keeps the jail environment and the ports collection updated with the latest security patches and software versions.

```sh
poudriere jail -u -j 14-2-RELEASE-amd64
poudriere ports -u -p default
```

---

## 11. Create the Package List

> Defines which ports should be built automatically, improving build control and avoiding manual selections.
> Create the file /usr/local/etc/poudriere.d/14-2-RELEASE-amd64-pkglist with the desired ports:

```
ports-mgmt/pkg
www/nginx
sysutils/tmux
```
---

## 12. Manual Build

> Manually triggers a bulk build to generate the package repository based on the jail and the selected ports tree.

```sh
poudriere bulk -j 14-2-RELEASE-amd64 -p default -f /usr/local/etc/poudriere.d/14-2-RELEASE-amd64-pkglist
```
---

## 13. Automate with Cron

> Automates the build process by running the script periodically without manual intervention.
> 
```cron
0 * * * * /usr/local/scripts/poudriere_build.sh
```
---

## 14. Access the Repository via Browser

> Allows users and clients to browse available packages and logs through a standard web browser.

```
http://pkg.domain.com.br/
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
  url: "https://pkg.domain.com.br/packages/14-2-RELEASE-amd64-default",
  mirror_type: "http",
  signature_type: "pubkey",
  pubkey: "/usr/local/etc/ssl/certs/poudriere.cert",
  enabled: yes
}
```

### 14.5. Test

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
poudriere bulk -j 14-2-RELEASE-amd64 print/texlive-texmf
```

### 16.4 Configure or change build options for a port

```sh
poudriere options -c -j 14-2-RELEASE-amd64 print/texlive-texmf
```

### 16.5 Build using a list of packages

```sh
poudriere bulk -j 14-2-RELEASE-amd64 -f /usr/local/etc/poudriere.d/14-2-RELEASE-amd64-pkglist
```

### 16.6 View logs from the latest builds

```sh
# List recent builds
poudriere status -j 14-2-RELEASE-amd64

# View errors from the latest build
less /usr/local/poudriere/data/logs/bulk/14-2-RELEASE-amd64-default/latest/logs/errors/*
```

### 16.7 Remove an existing jail

```sh
poudriere jail -d -j 14-2-RELEASE-amd64
```

### 16.8 Remove a ports tree

```sh
poudriere ports -d -p default
```

### 16.9 Check for orphaned (unused) packages

```sh
poudriere pkgclean -j 14-2-RELEASE-amd64 -p default -n
```

### 16.10 Check saved options for a specific port

```sh
poudriere options -j 14-2-RELEASE-amd64 -p default -s print/texlive-texmf
```

---

# ✅ Ready!
