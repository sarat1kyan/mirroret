# Uninstalling mirroret

The uninstaller removes what mirroret itself created. It never removes
nginx, Docker, Podman, debmirror or other OS packages.

Three equivalent entry points:

```bash
sudo ./uninstall.sh [opts]
sudo ./install.sh --uninstall [opts]
sudo mirroretctl uninstall [opts]
```

`make uninstall` runs `./uninstall.sh --list --all` (preview only).

`uninstall.sh` loads `/etc/mirroret/mirroret.conf` first, so a custom
`MIRRORET_BASE_DIR`, ports or service users are what gets removed.

---

## 1. Preview

```bash
sudo ./uninstall.sh --list        # components present + plan, changes nothing
sudo ./uninstall.sh --dry-run     # same plan with [plan] markers per step
```

Neither `--list` nor `--dry-run` requires root when invoked through
`install.sh --uninstall`.

---

## 2. Selective removal

Name any combination of components. No component named = `--all`.

| Flag | Removes |
|---|---|
| `--apt` | `/etc/apt/mirror.list`; `scripts/sync-apt-repos.sh`, `scripts/sync-apt-debmirror.sh`; `/etc/mirroret/targets/apt-*.json`; `/usr/local/bin/apt-mirror2` symlink and `/opt/mirroret-apt-mirror2`; the `mirroret-cache` unit (stopped, disabled, unit file and any `mirroret-cache.service.d/proxy.conf` drop-in), `scripts/run-cache.sh`, `/etc/mirroret/cache.json` |
| `--rpm` | `scripts/sync-rpm-repos.sh`, `scripts/sync-redhat-repos.sh`; `/etc/mirroret/targets/rpm-*.json` |
| `--pip` | `pypiserver.service` (+ proxy drop-in), `mirroret-pip` user, `/usr/local/bin/pypi-server` symlink (only if it is a symlink), `/opt/mirroret-pypiserver`, `scripts/sync-pip-packages.sh` |
| `--npm` | `verdaccio.service` (+ proxy drop-in), `mirroret-npm` user, `/etc/verdaccio/`, `scripts/sync-npm-packages.sh` |
| `--docker` | `docker-distribution`, `docker-registry` and `mirroret-registry` units (+ proxy drop-ins), the `mirroret-registry` container (docker or podman), `/etc/docker/registry/config.yml`, `/etc/docker-distribution/registry/config.yml`, `scripts/sync-docker-images.sh` (and its `.cache-mode-disabled` stub) |
| `--common` | nginx vhost (`sites-available`/`sites-enabled`/`conf.d` variants, then nginx reload); the managed cron block; `scripts/sync-all.sh`, `scripts/cleanup-all.sh`; `/etc/logrotate.d/mirroret`; `/usr/local/bin/mirroretctl` symlink; `/srv/mirroret/engines/`; `config/setup-mirror-client.sh`; `/etc/mirroret/targets` if empty; stale `/var/lock/mirroret-sync-*.lock`; SELinux file-context restore; firewall rule reversal; `--purge` targets |
| `--all` | every component above |

`scripts/` means `${MIRRORET_BASE_DIR}/scripts/`.

```bash
sudo ./uninstall.sh --docker           # registry only
sudo ./uninstall.sh --pip --npm        # pip + npm only
sudo ./uninstall.sh --common           # housekeeping only
```

---

## 3. Full removal including data

`--all` leaves mirror data, backups, TLS and GPG in place. `--purge`
(effective only together with `--common` / `--all`) also deletes:

- `${MIRRORET_BASE_DIR}` (default `/srv/mirroret/`) - the data tree
- `${MIRRORET_BACKUP_BASE}` (default `/var/backups/mirroret/`)
- `${MIRRORET_TLS_DIR}` (default `/etc/mirroret/tls/`)
- `${MIRRORET_GPG_HOMEDIR}` (default `/etc/mirroret/gnupg/`) - irreversible
- `/etc/mirroret/` if it is empty afterwards

The data tree and the GPG homedir each get a confirmation prompt unless
`--yes` is given.

```bash
sudo ./uninstall.sh --all --purge          # prompts
sudo ./uninstall.sh --all --purge --yes    # unattended
```

---

## 4. Modifiers

| Flag | Effect |
|---|---|
| `--purge` | also delete data, backups, TLS, GPG (prompts unless `--yes`) |
| `--keep-users` | do not `userdel` `mirroret-pip` / `mirroret-npm` |
| `--keep-firewall` | do not reverse ufw / firewalld / iptables rules |
| `--base-dir <p>` | override `MIRRORET_BASE_DIR` |
| `--yes`, `-y` | accept all confirmations |
| `--dry-run` | print the plan, exit |
| `--list` | print the plan, exit |
| `--help`, `-h` | usage |

Firewall reversal removes the ports for the selected components (web + TLS
port for `--common`, pip/docker/npm ports for their components), trying both
the source-restricted and the plain rule shapes so whichever the installer
wrote is matched.

---

## 5. Guarantees

- Idempotent: missing files, dead units and nonexistent users count as
  skips, not failures.
- Non-destructive by default: data, backups, GPG and TLS survive without
  `--purge`.
- Scoped: no OS packages are removed.
- The summary line reports `removed= skipped= failed=`; failed items are
  listed by name.

Verify the host afterwards with `sudo ./scripts/mirroret-debug.sh`.

---

## 6. Removing OS packages yourself

```bash
# Debian/Ubuntu
sudo apt-get remove --purge -y nginx debmirror docker-registry
sudo npm uninstall -g verdaccio

# RHEL family
sudo dnf remove -y nginx docker-distribution podman createrepo_c
sudo npm uninstall -g verdaccio
```

---

## 7. Rollback is not uninstall

`sudo ./install.sh --rollback <backup-id>` restores backed-up config files
and leaves services, data and directories in place. See
[ROLLBACK.md](ROLLBACK.md).
