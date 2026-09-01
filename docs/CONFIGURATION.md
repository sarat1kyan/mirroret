# Configuration reference

mirroret is configured with `MIRRORET_*` variables. They are read from
`/etc/mirroret/mirroret.conf` (plain shell assignments) and from the
environment.

## Where values come from, and which wins

1. **Environment** - `sudo MIRRORET_ENABLE_NPM=1 ./install.sh --upgrade`.
   Put the variable **after** `sudo`: `VAR=x sudo ./install.sh` sets it only
   for `sudo`, which strips it before running the script.
2. **`--config <path>`** - an explicit file, sourced during argument parsing.
3. **`/etc/mirroret/mirroret.conf`** - loaded automatically when present
   and `--config` was not given. Values already set in the environment are
   restored after sourcing, so **environment beats the conf file**.
4. **Built-in defaults** - the `${MIRRORET_X:-default}` values in `lib/` and
   `install.sh`, listed below.

How the conf file gets there:

- The first-run wizard (`sudo ./install.sh` on a fresh box with a TTY, no
  conf and no targets in the environment) writes it from its answers.
- A non-interactive first install seeds it from `config/mirroret.conf.example`.
- Or copy the example yourself and edit it.

Apply a change with `sudo ./install.sh --upgrade` (or `sudo mirroretctl upgrade`).
Generated sync scripts also re-read the conf at run time via their preamble,
so proxy/CA/`MIRRORET_SYNC_*` changes take effect on the next sync even
without an upgrade; anything that shapes generated files (targets, mode,
ports, components) needs the upgrade.

The generated scripts under `/srv/mirroret/scripts/` and the cache launcher
source the conf on every run and honour `MIRRORET_PROXY`, `MIRRORET_NO_PROXY`
and `MIRRORET_CA_BUNDLE` (see [PROXY_AND_CA.md](PROXY_AND_CA.md)).

---

## What to mirror

| Variable | Default | Description |
|---|---|---|
| `MIRRORET_APT_TARGETS` | *(empty)* | Space-separated `flavor:release[:arch,arch]` list for APT clients, e.g. `"ubuntu:jammy ubuntu:noble debian:bookworm"`. Flavors: `ubuntu`, `ubuntu-ports`, `debian`. Release accepts codename or version. |
| `MIRRORET_RPM_TARGETS` | *(empty)* | Same for RPM clients, `flavor:major[:arch,arch]`, e.g. `"ol:9 rocky:9 epel:9"`. Flavors: `rocky almalinux ol centos fedora epel rhel`. |
| `MIRRORET_APT_BACKPORTS` | `0` | Also mirror `<release>-backports` |
| `MIRRORET_APT_COMPONENTS` | per flavor | Override components. Ubuntu: `main restricted universe multiverse`; Debian: `main contrib non-free non-free-firmware`. `"main restricted"` is roughly a tenth of a full Ubuntu mirror. |
| `MIRRORET_RPM_REPOS` | per flavor | Repo ids to mirror; see `rpm_flavor_default_repos` in `lib/targets.sh` and [MULTI-DISTRO.md](MULTI-DISTRO.md). Applies to a single RPM target or the reposync engine. |
| `MIRRORET_RPM_ARCH` | `x86_64` | Architectures for RPM targets without a per-target arch list. `noarch` is always added. Add `i686` for 32-bit multilib. |
| `MIRRORET_APT_ARCH` | `amd64` | Legacy apt-mirror/debmirror architecture. The native engine takes arches from the target. |
| `MIRRORET_UBUNTU_CODENAME` | host OS | **Legacy fallback**: release to mirror when `MIRRORET_APT_TARGETS` is unset and the host is Ubuntu. Use `MIRRORET_APT_TARGETS`. |
| `MIRRORET_DEBIAN_CODENAME` | host OS | **Legacy fallback**, same for a Debian host. |
| `MIRRORET_RHEL_VERSION` | host OS | **Legacy fallback**: RPM major when `MIRRORET_RPM_TARGETS` is unset on a RHEL-family host. Use `MIRRORET_RPM_TARGETS`. |
| `MIRRORET_APT_FLAVOR` | `auto` | Legacy fallback flavor (`auto`, `ubuntu`, `debian`) when no APT target is set. |
| `MIRRORET_RPM_FLAVOR` | host `OS_ID` | Legacy fallback flavor directory when no RPM target is set. |

With neither `*_TARGETS` set, mirroret mirrors the release the **server**
runs; on a host that is neither Debian/Ubuntu nor RHEL-family, the
corresponding ecosystem resolves to no target and the installer says so.

## Storage mode and on-demand cache

| Variable | Default | Description |
|---|---|---|
| `MIRRORET_APT_MODE` | `mirror` | `mirror` (all packages up front), `hybrid` (indices up front, packages on demand; recommended), `cache` (everything on demand). The wizard asks; see [CACHE.md](CACHE.md). |
| `MIRRORET_CACHE_MAX_SIZE_GB` | `0` | LRU cap on cached package files; `0` = no cap. Apply with `sudo mirroretctl cache gc`. |
| `MIRRORET_CACHE_METADATA_TTL` | `300` | Seconds before a cached index is revalidated upstream |
| `MIRRORET_CACHE_PORT` | `8082` | Loopback port of `mirroret-cache`; not opened in the firewall |
| `MIRRORET_CACHE_CONFIG` | `/etc/mirroret/cache.json` | Generated route table |
| `MIRRORET_CACHE_UNIT` | `/etc/systemd/system/mirroret-cache.service` | Generated unit path |

## APT engine

| Variable | Default | Description |
|---|---|---|
| `MIRRORET_APT_MIRROR_TOOL` | `auto` | `auto` resolves to `native` (`engines/mirroret_apt.py`). `apt-mirror` and `debmirror` are legacy: Debian/Ubuntu hosts only, one flavor, metadata published before packages. |
| `MIRRORET_APT_SCHEME` | `http` | `http` or `https` for upstream archives. Use `https` behind a CONNECT-only proxy. Changes the outbound port (80 vs 443). |
| `MIRRORET_APT_REQUIRE_SIGNATURE` | `0` | Fail (not warn) when a Release signature cannot be verified on the mirror server. Needs the archive keyring installed locally. |
| `MIRRORET_APT_ALL_COMPRESSIONS` | `0` | Mirror every compression variant of each index instead of the best one |
| `MIRRORET_APT_SOURCE` | `0` | Mirror source packages |
| `MIRRORET_APT_TRANSLATIONS` | `1` | Mirror `Translation-<lang>` files |
| `MIRRORET_APT_LANGUAGES` | `en` | Space-separated languages for Translation files; written into the target spec |
| `MIRRORET_APT_DEP11` | `1` | Mirror AppStream dep11 metadata and icons |
| `MIRRORET_APT_CONTENTS` | `0` | Mirror `Contents-<arch>` (apt-file) indices |
| `MIRRORET_APT_DELETE` | `1` | Delete pool files upstream no longer lists |
| `MIRRORET_APT_JOBS` | engine default (8) | Parallel download workers |
| `MIRRORET_APT_UPSTREAM_HOST` | `archive.ubuntu.com` / `deb.debian.org` | Override main archive host |
| `MIRRORET_APT_SECURITY_HOST` | `security.ubuntu.com` / `deb.debian.org` | Override security archive host |
| `MIRRORET_APT_SECURITY_PATH` | per flavor | Legacy tools: path of the security archive (`/debian-security`) |
| `MIRRORET_APT_UPSTREAM_PATH` | `/ubuntu` / `/debian` | Legacy tools: archive path on the upstream host |
| `MIRRORET_APT_PORTS_HOST` | `ports.ubuntu.com` | Host for the `ubuntu-ports` flavor |
| `MIRRORET_APT_RESIGN` | `0` | Set to `1` only if you re-sign mirrored Release files yourself; makes client configs use `signed-by=MIRRORET_APT_KEYRING`. mirroret does not re-sign. |
| `MIRRORET_APT_THREADS` | `10` | Legacy apt-mirror download threads |
| `MIRRORET_APT_KEYRING_OVERRIDE` | flavor keyring | Legacy debmirror: keyring path used to verify upstream |
| `MIRRORET_APT_NGINX_PREFIX` | `/<flavor>` | Legacy tools: URL prefix nginx serves the single tree under |

## RPM engine

| Variable | Default | Description |
|---|---|---|
| `MIRRORET_RPM_ENGINE` | `auto` | `auto` = `native` (`engines/mirroret_rpm.py`) unless `MIRRORET_RPM_REPOS` names ids outside the catalog, then `reposync`. `reposync` needs dnf and repos the host itself is entitled to. |
| `MIRRORET_RPM_JOBS` | engine default (8) | Parallel download workers |
| `MIRRORET_RPM_NEWEST_ONLY` | `1` | Only the newest build of each package |
| `MIRRORET_RPM_SOURCE` | `0` | Mirror `.src.rpm` (multi-TB on large repos) |
| `MIRRORET_RPM_DELETE` | `1` | Delete packages upstream dropped |
| `MIRRORET_RPM_KEEP_UPSTREAM_METADATA` | `0` | Keep upstream `repodata/` instead of rebuilding. Only correct for a full, unfiltered mirror. |
| `MIRRORET_RPM_CLIENT_CERT` / `MIRRORET_RPM_CLIENT_KEY` | `/etc/pki/entitlement/*.pem` (auto) | TLS client certificate for `cdn.redhat.com` |
| `MIRRORET_RPM_ROCKY_BASE` | `https://dl.rockylinux.org/pub/rocky` | Upstream base URL |
| `MIRRORET_RPM_ALMA_BASE` | `https://repo.almalinux.org/almalinux` | Upstream base URL |
| `MIRRORET_RPM_ORACLE_BASE` | `https://yum.oracle.com/repo/OracleLinux` | Upstream base URL |
| `MIRRORET_RPM_CENTOS_BASE` | `https://mirror.stream.centos.org` | Upstream base URL |
| `MIRRORET_RPM_FEDORA_BASE` | `https://dl.fedoraproject.org/pub/fedora/linux` | Upstream base URL |
| `MIRRORET_RPM_EPEL_BASE` | `https://dl.fedoraproject.org/pub/epel` | Upstream base URL |
| `MIRRORET_RPM_RHEL_CDN` | `https://cdn.redhat.com/content/dist` | Upstream base URL |
| `MIRRORET_RPM_GPGKEY_URL` | *(empty)* | When set, client `.repo` files use `gpgkey=<url>` instead of the vendor key in `/etc/pki/rpm-gpg/` |

## Sync behaviour

| Variable | Default | Description |
|---|---|---|
| `MIRRORET_SYNC_HOUR` | `2` | Hour (0-23) of the nightly `sync-all.sh` cron entry |
| `MIRRORET_SYNC_MIN_FREE_GB` | `10` | Abort a sync when free space would drop below this. Engine/spec default 10; the wizard writes 15. |
| `MIRRORET_SYNC_ESTIMATE` | `1` | Estimate download size before syncing and abort if it would breach the floor |
| `MIRRORET_SYNC_SMOKE_TEST` | `1` | Legacy reposync: read each repo back with dnf after sync |
| `MIRRORET_SYNC_NICE` | `10` | `nice` level for sync processes (`ionice` idle class when available) |
| `MIRRORET_SYNC_TIMEOUT` | `12h` native engines, `6h` reposync | Wall-clock cap on one sync invocation |
| `MIRRORET_DOCKER_PULL_TIMEOUT` | `30m` | Cap on a single image pull in `sync-docker-images.sh` |
| `MIRRORET_LOG_KEEP_DAYS` | `30` | `cleanup-all.sh` deletes sync logs older than this; `0` disables |
| `MIRRORET_PIP_PLATFORMS` | `3.9:manylinux2014_x86_64 3.11:manylinux2014_x86_64 3.12:manylinux2014_x86_64` | Extra `python:platform` pairs to fetch wheels for; `-` = host only |
| `MIRRORET_PIP_PACKAGES_FILE` | *(empty, built-in list)* | File listing pip packages to sync |
| `MIRRORET_NPM_PACKAGES_FILE` | *(empty, built-in list)* | File listing npm packages to sync |
| `MIRRORET_DOCKER_IMAGES_FILE` | *(empty, built-in list)* | File listing images to pre-seed (hosted mode) |

## Paths

| Variable | Default | Description |
|---|---|---|
| `MIRRORET_BASE_DIR` | `/srv/mirroret` | Root for data, scripts, logs, client configs |
| `MIRRORET_BACKUP_BASE` | `/var/backups/mirroret` | Timestamped config backups |
| `MIRRORET_TARGETS_DIR` | `/etc/mirroret/targets` | Generated target specs |
| `MIRRORET_INSTALL_DIR` | checkout dir | Where `cleanup-all.sh` finds `lib/` |
| `MIRRORET_LOG_FILE` | `/var/log/mirroret-install.log` | Installer log |
| `MIRRORET_CONF` | `/etc/mirroret/mirroret.conf` | Conf file read by `mirroretctl` and `uninstall.sh` |
| `MIRRORET_PYPI_VENV` | `/opt/mirroret-pypiserver` | pypiserver venv when no distro package |

## Network and ports

| Variable | Default | Description |
|---|---|---|
| `MIRRORET_SERVER_IP` | `ip route get 1.1.1.1` | Address written into client configs |
| `MIRRORET_WEB_PORT` | `8080` | nginx HTTP (APT, RPM, `/config/`, proxies for `/pip/`, `/npm/`, `/v2/`) |
| `MIRRORET_TLS_PORT` | `8443` | nginx HTTPS, when TLS is configured |
| `MIRRORET_PIP_PORT` | `8081` | pypiserver |
| `MIRRORET_DOCKER_REGISTRY_PORT` | `5000` | Docker registry; listens on all interfaces |
| `MIRRORET_NPM_PORT` | `4873` | Verdaccio |
| `MIRRORET_NPM_BIND_ADDR` | `0.0.0.0` | Address Verdaccio binds |
| `MIRRORET_FIREWALL_SOURCE` | *(empty)* | Source CIDR for the firewall rules; empty = any source |
| `MIRRORET_PREFLIGHT_NETWORK` | `0` | Probe outbound HTTPS during preflight (`--network-preflight`) |

## Proxy and CA

| Variable | Default | Description |
|---|---|---|
| `MIRRORET_PROXY` | *(empty)* | Proxy URL for all upstream fetches. Mapped to `http_proxy`/`https_proxy` by every generated script and the cache launcher when those are unset. Loopback is always excluded. |
| `MIRRORET_NO_PROXY` | *(empty)* | Mapped to `no_proxy`; `localhost,127.0.0.1,::1` is appended automatically whenever a proxy is set |
| `http_proxy` / `https_proxy` / `no_proxy` | *(empty)* | Also honoured; take precedence over `MIRRORET_PROXY` when set. Upper/lower case are mirrored. |
| `MIRRORET_CA_BUNDLE` | *(empty)* | PEM bundle exported as `SSL_CERT_FILE`, `REQUESTS_CA_BUNDLE`, `PIP_CERT`, `NODE_EXTRA_CA_CERTS`, `CURL_CA_BUNDLE` in generated scripts and passed to the engines |

## TLS

| Variable | Default | Description |
|---|---|---|
| `MIRRORET_TLS_SELF_SIGNED` | `0` | Generate a 4096-bit self-signed cert (10 years) into `MIRRORET_TLS_DIR` (`--tls-self-signed`) |
| `MIRRORET_TLS_CERT` / `MIRRORET_TLS_KEY` | *(empty)* | Bring your own PEM cert and key |
| `MIRRORET_TLS_PORT` | `8443` | HTTPS listener |
| `MIRRORET_TLS_DIR` | `/etc/mirroret/tls` | Where the generated `cert.pem` / `key.pem` live |

Either `MIRRORET_TLS_SELF_SIGNED=1` or both `MIRRORET_TLS_CERT` and
`MIRRORET_TLS_KEY` enable the listener. When it is ready, the TLS port is
also opened in the firewall and the Docker client config switches to `https://`.

## GPG (custom repositories only)

Mirrored APT suites and RPM repos keep their **upstream** signatures; no key
is needed for them. These settings exist for operators who publish their own
packages or re-sign.

| Variable | Default | Description |
|---|---|---|
| `MIRRORET_GPG_AUTO` | `0` | Generate a 4096-bit RSA key if none exists (`--gpg-auto`) |
| `MIRRORET_GPG_NAME` / `MIRRORET_GPG_EMAIL` | `mirroret` / `mirroret@localhost` | Key identity |
| `MIRRORET_GPG_HOMEDIR` | `/etc/mirroret/gnupg` | Isolated GPG home |
| `MIRRORET_GPG_KEYID` | *(empty)* | Fingerprint of an existing key to use |
| `MIRRORET_APT_KEYRING` | `/srv/mirroret/config/mirroret.gpg` once a key exists | Binary keyring exported for clients; used in `signed-by=` only with `MIRRORET_APT_RESIGN=1` |

## Security / insecure modes (lab only)

| Variable | Default | Description |
|---|---|---|
| `MIRRORET_APT_INSECURE` | `0` | `trusted=yes` in APT client configs |
| `MIRRORET_RPM_INSECURE` | `0` | `gpgcheck=0` in RPM client configs |
| `MIRRORET_DOCKER_INSECURE` | `0` | `insecure-registries` in the Docker client config |
| `MIRRORET_PIP_INSECURE` | `0` | Marks the pip config as insecure (a plain-HTTP index carries `trusted-host` regardless) |

`--insecure` sets all four.

## Approval workflow

| Variable | Default | Description |
|---|---|---|
| `MIRRORET_APPROVAL_ENABLED` | `0` | Stage pip, npm **and RPM** downloads; nothing is served until promoted (`--approval-mode`) |
| `MIRRORET_NPM_ALLOW_ANON_PUBLISH` | `0` | Allow unauthenticated `npm publish` into Verdaccio (needed for npm promotion unless you `npm login`) |
| `MIRRORET_NPM_ALLOW_SELF_REGISTER` | `0` | Allow `npm adduser` against Verdaccio |

Layout: pip `staging/pip` -> `approved/pip`; npm `staging/npm` -> `approved/npm`
(+ `npm publish`); RPM `redhat/staging` -> `redhat/mirror` (+ `createrepo_c`).
Manage with `mirroretctl approve ...` ([OPERATIONS.md](OPERATIONS.md)).

## Docker registry

| Variable | Default | Description |
|---|---|---|
| `MIRRORET_DOCKER_BACKEND` | `auto` | `auto` (OS package, else container), `native` (`docker-distribution` / `docker-registry`), `container` (`registry:2` via docker or podman) |
| `MIRRORET_DOCKER_MODE` | `cache` | `cache` = pull-through proxy (rejects pushes); `hosted` = accepts `docker push`, pre-seed script generated |
| `MIRRORET_DOCKER_UPSTREAM_URL` | `https://registry-1.docker.io` | Upstream for cache mode |
| `MIRRORET_DOCKER_CONTAINER_NAME` | `mirroret-registry` | Container / podman unit name |

## Components and behaviour

| Variable | Default | Description |
|---|---|---|
| `MIRRORET_ENABLE_APT` / `_RPM` / `_PIP` / `_DOCKER` / `_NPM` | `1` | `0` disables a component (same as `--no-apt` etc.). The wizard writes these from its answers. |
| `MIRRORET_MIN_DISK_GB` | `50` | Free space required before installing; `0` skips |
| `MIRRORET_NON_INTERACTIVE` | `0` | Suppress prompts and skip the wizard (`--non-interactive`) |
| `LOG_LEVEL` | `INFO` | `DEBUG` or `INFO` (`--debug`) |
| `DRY_RUN` | `0` | Same as `--dry-run` |
| `MIRRORET_VERDACCIO_VERSION` | *(latest)* | Pin the Verdaccio version installed with npm |
| `MIRRORET_PYPI_USER` / `MIRRORET_NPM_USER` | `mirroret-pip` / `mirroret-npm` | Service users |

## Retention

| Variable | Default | Description |
|---|---|---|
| `MIRRORET_RETENTION_ENABLE` | `0` | Turn cleanup on |
| `MIRRORET_RETENTION_MODE` | `report` | `report` (dry run) or `prune` |
| `MIRRORET_RPM_KEEP_VERSIONS` | `3` | Newest builds to keep per RPM; `0` disables |
| `MIRRORET_PIP_KEEP_VERSIONS` | `3` | Newest files to keep per pip package |
| `MIRRORET_NPM_KEEP_DAYS` | `180` | Drop npm tarballs older than N days |
| `MIRRORET_NPM_PRUNE_STORAGE` | `0` | Allow deleting `.tgz` straight out of Verdaccio storage (leaves stale metadata) |
| `MIRRORET_DOCKER_GC` | `0` | Weekly `registry garbage-collect` |
| `MIRRORET_CLEANUP_HOUR` / `MIRRORET_CLEANUP_DOW` | `3` / `0` | Weekly cleanup cron (Sunday 03:00) |

See [RETENTION.md](RETENTION.md).

---

## Runtime-only variables

Set by the libraries during a run; not meant for the conf file.

| Variable | Set by | Description |
|---|---|---|
| `MIRRORET_TLS_ENABLED` | `lib/tls.sh` | `1` once cert and key are in place |
| `MIRRORET_APT_RESOLVED_TOOL` | `lib/apt.sh` | `native`, `apt-mirror`, `apt-mirror2` or `debmirror` |
| `MIRRORET_RPM_RESOLVED_ENGINE` | `lib/rpm.sh` | `native` or `reposync` |
| `MIRRORET_APT_DATA_PATH` | `lib/apt.sh` | Legacy tools: directory nginx serves |
| `MIRRORET_APT_SPECS` / `MIRRORET_RPM_SPECS` | `lib/targets.sh` | Generated spec file lists |
| `MIRRORET_MANAGED_MARKER` | `lib/common.sh` | Sentinel line in generated files (`mirroret-managed`) |
| `DISTRO_TYPE`, `OS_ID`, `OS_VER`, `OS_CODENAME`, `PKG_MGR` | `lib/distro.sh` | Host detection |

---

## Examples

Hybrid Ubuntu + Debian mirror plus Oracle Linux, behind a proxy:

```bash
# /etc/mirroret/mirroret.conf
MIRRORET_APT_TARGETS="ubuntu:jammy:amd64 ubuntu:noble:amd64 debian:bookworm:amd64"
MIRRORET_RPM_TARGETS="ol:9"
MIRRORET_APT_MODE="hybrid"
MIRRORET_PROXY="http://proxy.example.internal:3128"
MIRRORET_APT_SCHEME="https"
MIRRORET_SYNC_MIN_FREE_GB="15"
MIRRORET_FIREWALL_SOURCE="10.0.0.0/8"
```

```bash
sudo ./install.sh --upgrade
```

APT-only, full mirror, subnet-restricted, one-shot:

```bash
sudo MIRRORET_APT_TARGETS="ubuntu:noble" MIRRORET_FIREWALL_SOURCE=10.0.0.0/8 \
     ./install.sh --no-rpm --no-pip --no-docker --no-npm --non-interactive
```

Bring your own TLS certificate:

```bash
sudo MIRRORET_TLS_CERT=/etc/ssl/certs/server.crt \
     MIRRORET_TLS_KEY=/etc/ssl/private/server.key \
     ./install.sh --upgrade
```
