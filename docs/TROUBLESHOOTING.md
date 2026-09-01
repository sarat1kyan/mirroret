# Troubleshooting

## Start here

```bash
mirroretctl targets        # is anything configured, and did it sync?
mirroretctl client verify  # do the client configs match what is published?
mirroretctl logs errors    # what failed recently
mirroretctl doctor         # full read-only diagnostic (--net probes upstream)
mirroretctl report         # one redacted text file to send to someone else
sudo ./install.sh --check  # validation only - it does NOT regenerate anything
```

`--check` (alias `--validate`) inspects the installation and exits. To
regenerate configs, scripts, units and the cron block, run
`sudo ./install.sh --upgrade`.

Service logs: `journalctl -u nginx -u pypiserver -u verdaccio -u mirroret-cache -n 100`.
Sync logs: `/srv/mirroret/logs/` (`mirroretctl logs list|tail|show|errors`).

---

## Installation

### The wizard did not appear

It runs only when all of these hold: not `--upgrade`, not `--non-interactive`,
not `--dry-run`, stdin is a TTY, `/etc/mirroret/mirroret.conf` does not
exist, and neither `MIRRORET_APT_TARGETS` nor `MIRRORET_RPM_TARGETS` is in
the environment. Otherwise the conf is used (or seeded from the example).

### An environment variable was ignored

`VAR=x sudo ./install.sh` sets the variable for `sudo`, which drops it. Use
`sudo VAR=x ./install.sh`.

### `--upgrade requires an existing install`

`--upgrade` refuses to run when `MIRRORET_BASE_DIR` is missing. Run a full
`sudo ./install.sh` first.

### Preflight fails on disk space

`MIRRORET_MIN_DISK_GB` (default 50) is checked before installing. Lower it
(or `0`) for a small pilot; it is separate from the sync-time floor
`MIRRORET_SYNC_MIN_FREE_GB`.

---

## nginx

### nginx fails to start / `nginx -t` fails

```bash
sudo nginx -t
journalctl -u nginx -n 100 --no-pager
ss -tlnp | grep ':8080'            # port conflict
```

The installer validates the vhost before placing it and rolls back to the
previous file if `nginx -t` fails afterwards, so a broken vhost usually
means a hand edit. Regenerate with `sudo ./install.sh --upgrade`.

### 403 / 404 on a path that exists on disk

Check the alias matches the tree. Native APT trees are served as
`/<flavor>/` from `/srv/mirroret/apt/<flavor>/`; RPM as `/redhat/` from
`/srv/mirroret/redhat/mirror/`.

```bash
ls -la /srv/mirroret/apt/ubuntu/dists/
curl -I http://localhost:8080/ubuntu/dists/noble/InRelease

# SELinux (RHEL):
restorecon -Rv /srv/mirroret
```

`/logs`, `/scripts`, `/staging`, `/engines`, `/backups`, `/targets` return
404 by design.

### 502 on `/pip/`, `/npm/`, `/v2/`

The backend is down: `systemctl status pypiserver verdaccio docker-distribution docker-registry`.

### 502 on a package in hybrid/cache mode

nginx handed a cache miss to `mirroret-cache` and it did not answer.

```bash
mirroretctl cache status
systemctl status mirroret-cache
journalctl -u mirroret-cache -n 50
mirroretctl cache routes           # is the flavor routed at all?
```

No routes means `MIRRORET_APT_TARGETS` was empty when the config was
generated: set it and `sudo ./install.sh --upgrade`. Behind a corporate
proxy, see [CACHE.md](CACHE.md) and [PROXY_AND_CA.md](PROXY_AND_CA.md).

---

## APT mirror

### Nothing is ever downloaded and nothing reports an error

No APT target is configured. `mirroretctl targets` shows none, and the
installer warned "APT mirroring is enabled but no target resolved". A
non-Debian host has nothing to guess from:

```bash
sudo mirroretctl config edit       # MIRRORET_APT_TARGETS="ubuntu:noble debian:bookworm"
sudo mirroretctl upgrade
mirroretctl targets
sudo mirroretctl sync apt
```

### `mirroretctl verify` reports missing files

The published `Release` names files that are not on disk. The native engine
publishes `Release` only after everything it lists is present, so this
normally means a legacy apt-mirror/debmirror tree, a manual deletion, or a
tree written by an older engine (no `.mirroret-manifest.json`, so every entry
is checked rather than only the mirrored ones). Re-run `sudo mirroretctl sync apt`.
A filtered mirror with a manifest is **not** a failure: skipped entries are
reported as `skipped_by_config`.

### `signature: NOT verified locally`

Expected on a mirror server without the archive keyring (any RHEL host).
Clients still verify the mirrored signature themselves. To make it fatal,
install `ubuntu-keyring` / `debian-archive-keyring` on the server and set
`MIRRORET_APT_REQUIRE_SIGNATURE=1`.

### `sha256 mismatch` on one file

Upstream was mid-publish or a proxy truncated the transfer. The engine
retries and refuses to publish the suite, leaving the previous state
serving. Re-run; if it persists, try another `MIRRORET_APT_UPSTREAM_HOST`.

### Hybrid mode: sync says "metadata-only: skipping N package(s)"

Correct. Hybrid mirrors indices only; packages arrive on first request.
The line to look for is `published: dists/<suite>`.

### Clients get `NO_PUBKEY`

The mirrored `Release` is signed by Ubuntu/Debian, so either:

- the **client** lacks its own distro keyring (`ubuntu-keyring` /
  `debian-archive-keyring`), which is unusual on a stock system - reinstall
  the package; or
- the server has `MIRRORET_APT_RESIGN=1`, so the client config says
  `signed-by=/etc/apt/keyrings/mirroret.gpg`, but nobody re-signed the
  `Release` files with that key. Unset `MIRRORET_APT_RESIGN` and
  `sudo ./install.sh --upgrade`, or actually re-sign and import the key
  ([SECURITY.md](SECURITY.md)).

`--gpg-auto` does not fix this: it creates a key for **your** packages and
does not change how mirrored suites are signed.

### `apt-get update` 404s on a `Packages` file

The client config advertises a suite/arch the server has not published.

```bash
mirroretctl client verify          # names the mismatch
sudo mirroretctl sync apt
```

If the client has `dpkg --add-architecture i386` and the mirror is amd64
only, the generated config's `arch=amd64` pin prevents the 404; an old
hand-written config may lack it.

### apt-mirror / debmirror (legacy tools only)

Only relevant with `MIRRORET_APT_MIRROR_TOOL=apt-mirror|debmirror`.

```bash
tail -100 /srv/mirroret/logs/sync-apt-*.log
cat /etc/apt/mirror.list                                 # apt-mirror
sudo apt-get install -y ubuntu-keyring                   # debmirror NO_PUBKEY
sudo /srv/mirroret/scripts/sync-apt-debmirror.sh
```

The default `auto` tool is the native engine, which needs neither. To move
off the legacy tools, set `MIRRORET_APT_MIRROR_TOOL=auto` and
`MIRRORET_APT_TARGETS`, then `sudo ./install.sh --upgrade`.

---

## RPM

### Clients resolve a package, then 404 downloading it

Metadata advertises packages that are not on disk: a filtered mirror served
with upstream's metadata. The native engine rewrites metadata to match the
disk, so check:

```bash
grep KEEP_UPSTREAM_METADATA /etc/mirroret/mirroret.conf   # should be 0 or unset
sudo mirroretctl sync rpm
mirroretctl client simulate                               # resolve AND download
```

### `dnf install glibc.i686` -> "No match for argument"

i686 was never mirrored:

```bash
# MIRRORET_RPM_ARCH="x86_64 i686"   (or ol:9:x86_64,i686 in the target)
sudo mirroretctl upgrade && sudo mirroretctl sync rpm
```

### `repomd.xml` signature error on the client

Remove `repo_gpgcheck=1` from the client's `.repo`; the generated files do
not set it. A filtered mirror rebuilds `repomd.xml`. `gpgcheck=1` still
verifies package signatures.

### "did not return repository metadata" / "not <repomd>"

The URL answered with something else - almost always a proxy block page.

```bash
curl -sS -o /dev/null -w '%{http_code}\n' \
    https://yum.oracle.com/repo/OracleLinux/OL9/baseos/latest/x86_64/repodata/repomd.xml
```

A 403 is proxy policy. See [PROXY_AND_CA.md](PROXY_AND_CA.md).

### Unknown repo id

`Unknown ol repo 'xyz' - skipping it` in the install output. Valid ids per
flavor are in [MULTI-DISTRO.md](MULTI-DISTRO.md); legacy dnf ids
(`ol9_baseos_latest`, `rhel-9-for-x86_64-baseos-rpms`) are translated.

### reposync (legacy engine only)

Only with `MIRRORET_RPM_ENGINE=reposync`, or `auto` when `MIRRORET_RPM_REPOS`
names ids outside the catalog.

```bash
tail -100 /srv/mirroret/logs/sync-redhat-*.log
which reposync || dnf install -y yum-utils
dnf repolist -v                    # reposync can only mirror repos this host has
```

### Clients report a GPG key error on RPM

The generated `.repo` points at the vendor key in `/etc/pki/rpm-gpg/`. If it
is missing on the client, reinstall the release package
(`oraclelinux-release`, `rocky-release`, ...). `MIRRORET_RPM_GPGKEY_URL` is
only for packages you signed yourself.

---

## On-demand cache (hybrid / cache mode)

```bash
mirroretctl cache status           # daemon up? hit rate? bytes from upstream?
mirroretctl cache routes           # flavor -> upstream list
mirroretctl cache size             # disk per flavor
journalctl -u mirroret-cache -n 50
```

- **Daemon not responding**: `systemctl status mirroret-cache`. A crash loop
  with "no routes" means `cache.json` is empty - set targets and upgrade.
- **Everything 502s behind a proxy**: the daemon uses `MIRRORET_PROXY` /
  `http_proxy` from the conf via the launcher preamble. CONNECT-only proxies
  also need `MIRRORET_APT_SCHEME=https`. Then `sudo ./install.sh --upgrade`.
- **Cap not applied**: `sudo mirroretctl cache gc` restarts the daemon with
  the new `MIRRORET_CACHE_MAX_SIZE_GB`.

---

## pypiserver / pip

```bash
journalctl -u pypiserver -n 100 --no-pager
ss -tlnp | grep 8081
systemctl cat pypiserver | grep ExecStart      # serve dir: pip/approved or approved/pip
curl http://localhost:8081/simple/
```

A client with a Python version the server did not fetch wheels for gets
"no matching distribution" for C-extension packages: extend
`MIRRORET_PIP_PLATFORMS` and re-sync.

---

## Docker registry

```bash
systemctl status docker-distribution      # RHEL native
systemctl status docker-registry          # Debian native
docker ps -a --filter name=mirroret-registry ; docker logs mirroret-registry
curl http://localhost:5000/v2/
```

- **Push rejected**: `MIRRORET_DOCKER_MODE=cache` is a pull-through proxy and
  rejects pushes by design. Use `hosted`.
- **Client refuses http registry**: without TLS the generated
  `docker-daemon.json` must list `SERVER:5000` in `insecure-registries`;
  re-fetch it from `/config/`. With TLS, trust `cert.pem`
  ([SECURITY.md](SECURITY.md)).

---

## Verdaccio / npm

```bash
journalctl -u verdaccio -n 100 --no-pager
ls -la /etc/verdaccio/htpasswd
systemctl cat verdaccio | grep ExecStart
curl http://localhost:4873/
```

- **Binds only to localhost**: `MIRRORET_NPM_BIND_ADDR` must name a host
  (default `0.0.0.0`).
- **E401 on publish/approve**: `npm login --registry http://localhost:4873/`
  or `MIRRORET_NPM_ALLOW_ANON_PUBLISH=1`.
- **404 for a package in approval mode**: expected; only approved packages
  are served and the npmjs uplink is disabled.

---

## Approval workflow

```bash
mirroretctl approve list           # nothing staged?
ls /srv/mirroret/staging/pip /srv/mirroret/staging/npm /srv/mirroret/redhat/staging
grep -i staging /srv/mirroret/scripts/sync-pip-packages.sh
```

If the sync scripts write to `pip/approved` instead of `staging/pip`, the
install ran without approval mode: set `MIRRORET_APPROVAL_ENABLED=1` and
`sudo ./install.sh --upgrade`. Approved RPMs stay invisible until
`createrepo_c` rebuilt repodata; the approval warns if it is missing.

---

## TLS

```bash
openssl x509 -noout -modulus -in /etc/mirroret/tls/cert.pem | md5sum
openssl rsa  -noout -modulus -in /etc/mirroret/tls/key.pem  | md5sum   # must match
grep -n ssl_certificate /etc/nginx/conf.d/mirroret-unified.conf \
    /etc/nginx/sites-available/mirroret-unified 2>/dev/null
ss -tlnp | grep 8443
```

"certificate verify failed" on a client: the self-signed cert is not
trusted there. Copy `/etc/mirroret/tls/cert.pem` over and import it.

---

## Sync scheduling

```bash
sudo crontab -l                    # managed block between the >>> <<< markers
mirroretctl sync status            # running syncs and locks
sudo mirroretctl sync stop
```

"another APT sync is already running": a lock in `/var/lock/mirroret-sync-*.lock`
is held. Watch it with `mirroretctl logs tail`, or stop it. A sync that
exceeds `MIRRORET_SYNC_TIMEOUT` is killed and the lock released.

---

## Common error table

| Error | Likely cause | Fix |
|---|---|---|
| `Permission denied` | not root | `sudo ./install.sh` |
| `nginx: [emerg] bind() failed` | port in use | `ss -tlnp \| grep <port>` |
| `NO_PUBKEY` on APT clients | client missing its distro keyring, or `MIRRORET_APT_RESIGN=1` without re-signing | see APT section |
| `Packages ... 404` on APT clients | suite not published | `mirroretctl client verify`, `sudo mirroretctl sync apt` |
| `502 Bad Gateway` on a package | cache daemon down (hybrid/cache) | `mirroretctl cache status` |
| `ABORT: ... would leave less than N GB free` | disk floor | reduce components/targets, or raise `MIRRORET_SYNC_MIN_FREE_GB` awareness |
| `No space left on device` | disk full | `df -h /srv/mirroret`; consider `MIRRORET_APT_MODE=hybrid` |
| `did not return repository metadata` | proxy block page | allow-list the upstream host |
| `SSL: CERTIFICATE_VERIFY_FAILED` | self-signed cert not trusted, or TLS-inspecting proxy | import the CA |
| `E401 Unauthorized` (npm) | Verdaccio auth | `npm login` or `MIRRORET_NPM_ALLOW_ANON_PUBLISH=1` |
| `another ... sync is already running` | lock held | `mirroretctl sync status` / `sudo mirroretctl sync stop` |
| `--upgrade requires an existing install` | no base dir | full `sudo ./install.sh` first |
