# Operations

## Status and logs

```bash
mirroretctl status                  # services, ports, disk, last sync, cron
mirroretctl service list            # unit states
mirroretctl logs list|tail|show|errors
mirroretctl sync status             # running syncs, lock state
mirroretctl sync last               # last line of each newest sync log
```

Units: `nginx`, `pypiserver`, `verdaccio`, `mirroret-cache` (hybrid/cache
mode), and one of `docker-distribution` (RHEL native), `docker-registry`
(Debian native) or the `mirroret-registry` container/podman unit.

```bash
journalctl -u pypiserver -u verdaccio -u mirroret-cache -n 50 --no-pager
tail -f /var/log/nginx/mirroret-unified-access.log
ls -lth /srv/mirroret/logs/ | head          # one file per sync run
```

---

## Sync

```bash
sudo mirroretctl sync all           # = /srv/mirroret/scripts/sync-all.sh (what cron runs)
sudo mirroretctl sync apt
sudo mirroretctl sync rpm
sudo mirroretctl sync pip
sudo mirroretctl sync npm
sudo mirroretctl sync docker        # hosted mode only
sudo mirroretctl sync stop
```

Each ecosystem has a generated script under `/srv/mirroret/scripts/`
(`sync-apt-repos.sh`, `sync-rpm-repos.sh`, `sync-pip-packages.sh`,
`sync-npm-packages.sh`, `sync-docker-images.sh`); `mirroretctl sync` runs
them. Each takes a lock in `/var/lock/mirroret-sync-*.lock`, writes a
timestamped log, runs under `nice`/`ionice`, is capped by
`MIRRORET_SYNC_TIMEOUT`, and re-reads `/etc/mirroret/mirroret.conf` on every
run (proxy, CA, disk floor).

The APT script ends with `verify-mirror.sh`; run it any time with
`mirroretctl verify [--flavor F] [--suite S] [--json]`.

Hybrid/cache mode: `sudo mirroretctl sync apt` refreshes indices only;
packages arrive on demand. `mirroretctl cache status|routes|size` and
`sudo mirroretctl cache gc` operate the daemon ([CACHE.md](CACHE.md)).

### Schedule

`install.sh` writes a managed block into root's crontab:

```
# >>> mirroret managed (do not edit between markers) >>>
0 2 * * *   /srv/mirroret/scripts/sync-all.sh
0 3 * * 0   /srv/mirroret/scripts/cleanup-all.sh
# <<< mirroret managed <<<
```

Change it with `MIRRORET_SYNC_HOUR`, `MIRRORET_CLEANUP_HOUR`,
`MIRRORET_CLEANUP_DOW` in the conf, then `sudo mirroretctl upgrade`. Hand
edits between the markers are replaced on the next upgrade.

### Package lists for pip / npm / Docker

```bash
sudo tee /etc/mirroret/pip-packages.txt <<'EOF2'
requests
flask
EOF2
# in /etc/mirroret/mirroret.conf:
#   MIRRORET_PIP_PACKAGES_FILE=/etc/mirroret/pip-packages.txt
#   MIRRORET_NPM_PACKAGES_FILE=/etc/mirroret/npm-packages.txt
#   MIRRORET_DOCKER_IMAGES_FILE=/etc/mirroret/docker-images.txt   (hosted mode)
sudo mirroretctl upgrade
```

Editing the generated scripts directly works only if you remove their
`mirroret-managed` marker line, after which upgrades leave them alone
([RETENTION.md](RETENTION.md)).

---

## Changing what is mirrored

```bash
sudo mirroretctl config edit        # MIRRORET_APT_TARGETS / MIRRORET_RPM_TARGETS / MIRRORET_APT_MODE
sudo mirroretctl upgrade            # regenerates specs, nginx, cache routes, client configs
mirroretctl targets
sudo mirroretctl sync apt
```

Removing a target drops its spec so it stops syncing; its data stays on disk
until you delete `/srv/mirroret/apt/<flavor>/` or
`/srv/mirroret/redhat/mirror/<flavor>/<major>/` yourself.

Do not hand-edit `dists/`, `pool/` or `repodata/`: APT `Release` files are
upstream-signed and a rebuilt index would fail client verification; RPM
repodata is rebuilt by the engine to match the disk. For your own packages
use a separate repository (`scripts/mirror-apt-extra.sh` for third-party APT
repos, or the approval workflow for RPMs).

---

## Approval workflow

With `MIRRORET_APPROVAL_ENABLED=1` (`--approval-mode`), syncs stage downloads
and nothing reaches a client until an operator promotes it. Covers **pip,
npm and RPM**.

```bash
mirroretctl approve list            # everything waiting
mirroretctl approve list rpm        # full staged RPM file list

sudo mirroretctl approve all        # promote everything
sudo mirroretctl approve all rpm    # one kind: rpm | pip | npm
sudo mirroretctl approve rpm glibc  # by name fragment
sudo mirroretctl approve pip requests
sudo mirroretctl approve deny rpm telnet     # delete from staging
sudo mirroretctl approve deny npm oldlib
```

The same operations exist as `install.sh` flags (`--list-staging`,
`--approve-all-pip`, `--approve-all-npm`, `--approve-all-rpm`,
`--approve-package <n>`, `--approve-rpm <n>`, `--exclude-pip <n>`,
`--exclude-npm <n>`, `--exclude-rpm <n>`).

| Kind | Staged in | Promoted to | Extra step on approval |
|---|---|---|---|
| pip | `staging/pip` | `approved/pip` | none; pypiserver serves the directory |
| npm | `staging/npm` | `approved/npm` | `npm publish` into Verdaccio |
| rpm | `redhat/staging` | `redhat/mirror` | `createrepo_c` rebuild of each touched repo |

Notes:

- An approved `.rpm` is invisible to dnf until repodata lists it; if
  `createrepo_c` is missing the approval warns and the packages stay hidden.
- With approval on, the generated Verdaccio config has **no npmjs uplink**:
  a package nobody approved returns 404 instead of being fetched live.
- npm promotion needs credentials: `npm login --registry http://localhost:4873/`
  once, or `MIRRORET_NPM_ALLOW_ANON_PUBLISH=1`.
- RPM syncs in approval mode still exit non-zero on download failures, so
  cron failures are not masked.

---

## Docker registry

```bash
# mode: MIRRORET_DOCKER_MODE=cache (pull-through, rejects push) | hosted (accepts push)
# backend: MIRRORET_DOCKER_BACKEND=auto | native | container
curl http://localhost:5000/v2/_catalog
```

| Backend | Service | Config |
|---|---|---|
| native, RHEL family | `docker-distribution` | `/etc/docker-distribution/registry/config.yml` |
| native, Debian/Ubuntu | `docker-registry` | `/etc/docker/registry/config.yml` |
| container (docker or podman) | `mirroret-registry` | `/etc/docker/registry/config.yml` (mounted) |

Storage: `/srv/mirroret/docker/registry/`. Garbage collection runs weekly
from `cleanup-all.sh` when `MIRRORET_DOCKER_GC=1` (brief restart); by hand:

```bash
sudo registry garbage-collect /etc/docker-distribution/registry/config.yml   # RHEL native
sudo registry garbage-collect /etc/docker/registry/config.yml                # Debian native
docker exec mirroret-registry registry garbage-collect /etc/docker/registry/config.yml
```

then restart the service. Pre-seeding (`sync-docker-images.sh`, hosted mode)
needs a `docker` or `podman` CLI on the server.

---

## Disk

```bash
du -sh /srv/mirroret/*
df -h /srv/mirroret
mirroretctl cache size             # hybrid/cache: per-flavor cache usage
```

Levers, largest first: `MIRRORET_APT_MODE=hybrid` (a few GB instead of
hundreds), `MIRRORET_APT_COMPONENTS="main restricted"`, fewer targets,
`MIRRORET_CACHE_MAX_SIZE_GB` for the on-demand cache, retention for RPM /
pip / npm ([RETENTION.md](RETENTION.md)). Syncs abort before breaching
`MIRRORET_SYNC_MIN_FREE_GB`.

Do not delete files out of an APT `pool/` by hand; the signed indices would
still list them.

---

## Log rotation

`install.sh` writes `/etc/logrotate.d/mirroret` (managed; it carries the
`mirroret-managed` marker and is regenerated on upgrade unless you remove
the marker):

- `/srv/mirroret/logs/*.log`: weekly, keep 8, compressed
- `/var/log/mirroret-install.log`, `/var/log/mirroret-uninstall.log`:
  monthly, keep 6

Because every sync run creates a new timestamped file, `cleanup-all.sh`
additionally deletes logs older than `MIRRORET_LOG_KEEP_DAYS` (default 30;
`0` disables).

---

## Service control

```bash
sudo mirroretctl service restart nginx
sudo mirroretctl service restart pypiserver
sudo mirroretctl service restart verdaccio
sudo mirroretctl service restart mirroret-cache
mirroretctl service logs verdaccio 100
```

nginx changes: `sudo nginx -t && sudo systemctl reload nginx`.

---

## Validation

```bash
sudo mirroretctl check              # = sudo ./install.sh --check; validates, regenerates nothing
mirroretctl verify                  # APT tree integrity against each published Release
mirroretctl serve                   # every HTTP endpoint locally
mirroretctl client verify           # client configs vs published suites/repos
mirroretctl doctor                  # everything
```

---

## Routine

- After each nightly sync: `mirroretctl logs errors`, `mirroretctl targets`.
- Weekly: `df -h /srv/mirroret`, `mirroretctl cache status` (hybrid/cache),
  `mirroretctl approve list` if approval mode is on.
- After editing the conf: `sudo mirroretctl upgrade`, then `mirroretctl config diff`.
- After updating the checkout: `sudo ./install.sh --upgrade`, `mirroretctl doctor`.

---

## Port reference

| Port | Variable | Service |
|---|---|---|
| 8080 | `MIRRORET_WEB_PORT` | nginx HTTP: APT, RPM, `/config/`, proxies for `/pip/`, `/npm/`, `/v2/` |
| 8443 | `MIRRORET_TLS_PORT` | nginx HTTPS (when TLS configured) |
| 8081 | `MIRRORET_PIP_PORT` | pypiserver |
| 5000 | `MIRRORET_DOCKER_REGISTRY_PORT` | Docker registry, all interfaces |
| 4873 | `MIRRORET_NPM_PORT` | Verdaccio |
| 8082 | `MIRRORET_CACHE_PORT` | `mirroret-cache`, loopback only |

Firewall commands: [NETWORK_ACCESS.md](NETWORK_ACCESS.md).
