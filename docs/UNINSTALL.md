# Uninstalling Mirroret

The uninstaller removes things mirroret itself created. It **never**
removes nginx, Docker, Podman, debmirror, or other OS packages - those
may be in use by other things on the host.

Three ways to invoke it; they're equivalent:

```bash
sudo ./uninstall.sh [opts]
sudo ./install.sh --uninstall [opts]
sudo make uninstall # implies --list --all (preview only)
```

---

## 1. Preview before doing anything

```bash
sudo ./uninstall.sh --list
```

`--list` prints which mirroret components exist on the host, the full
removal plan, and exits without changing anything. Use it before every
real run - especially on production servers.

`--dry-run` is similar but logs each step with a `[plan]` marker.

Neither `--list` nor `--dry-run` requires root.

---

## 2. Remove selectively

You can target individual components in any combination. The defaults
(when no target is named) are equivalent to `--all`.

```bash
# Just stop using Docker - leave everything else running:
sudo ./uninstall.sh --docker

# Drop pip + npm but keep distro mirrors and the Docker registry:
sudo ./uninstall.sh --pip --npm

# Remove a stale RPM sync script after switching to RHEL-only:
sudo ./uninstall.sh --rpm

# Common housekeeping only (nginx vhost, cron, sync-all.sh) without
# touching any of the per-language services:
sudo ./uninstall.sh --common
```

| Flag | Removes |
|---|---|
| `--apt` | `/etc/apt/mirror.list`, `sync-apt-debmirror.sh`, apt-mirror2 venv |
| `--rpm` | `sync-redhat-repos.sh` |
| `--pip` | `pypiserver.service`, `mirroret-pip` user, `/opt/mirroret-pypiserver`, `sync-pip-packages.sh` |
| `--npm` | `verdaccio.service`, `mirroret-npm` user, `/etc/verdaccio/`, `sync-npm-packages.sh` |
| `--docker` | `docker-distribution` / `docker-registry` / `mirroret-registry` services, the registry container, `/etc/docker/registry/`, `/etc/docker-distribution/registry/`, `sync-docker-images.sh` |
| `--common` | nginx vhost, cron managed block, `sync-all.sh`, SELinux file-context restore, firewall rule reversal |
| `--all` | every component above |

---

## 3. Full removal including data

`--all` deletes services and configs but **never** deletes mirror data,
backups, or the GPG signing key. Those are explicitly opt-in:

```bash
sudo ./uninstall.sh --all --purge
```

`--purge` ALSO deletes:

- `/srv/mirroret/` - the mirror data tree (hundreds of GB)
- `/var/backups/mirroret/` - every backup snapshot install.sh has ever taken
- `/etc/mirroret/tls/` - TLS cert + key
- `/etc/mirroret/gnupg/` - the GPG signing key

Each of those gets a separate interactive confirmation. Add `--yes` to
skip them (e.g. for unattended decommissioning).

```bash
# Unattended full wipe (CI / decommissioning).
sudo ./uninstall.sh --all --purge --yes
```

---

## 4. Common modifiers

| Flag | Effect |
|---|---|
| `--purge` | Also delete mirror data, backups, TLS, GPG. Prompts unless `--yes`. |
| `--keep-users` | Do not delete `mirroret-pip` / `mirroret-npm` system users |
| `--keep-firewall` | Do not reverse ufw / firewalld / iptables rules |
| `--base-dir <p>` | Override `MIRRORET_BASE_DIR` (default `/srv/mirroret`) |
| `--yes`, `-y` | Accept all confirmations |
| `--dry-run` | Print plan, change nothing |
| `--list` | Same as `--dry-run` |
| `--help`, `-h` | Show flag reference |

---

## 5. Behavior guarantees

- **Idempotent.** Re-running on an already-partially-removed install is
  safe - missing files / dead services / nonexistent users count as
  `skip`, not as failures.
- **Non-destructive by default.** Data, backups, GPG keys, and TLS certs
  are kept unless you explicitly pass `--purge`.
- **Scoped.** No third-party OS packages are removed. If you want
  Docker / Podman / nginx gone, do that yourself with your package
  manager after the uninstaller finishes.
- **Verifiable.** After uninstalling, run `./scripts/mirroret-debug.sh`
  to confirm the host is clean - listening ports free, services absent,
  data tree absent.

---

## 6. Examples

```bash
# Show what would happen on a production server, change nothing:
sudo ./uninstall.sh --list

# Remove just the Docker pieces (registry container, config, native service):
sudo ./uninstall.sh --docker --yes

# Decommission entirely, including all data:
sudo ./uninstall.sh --all --purge --yes

# Step the uninstall through interactively, but keep the firewall rules
# (because you have other services on the same ports):
sudo ./uninstall.sh --all --keep-firewall

# Verify the host is clean afterwards:
sudo ./scripts/mirroret-debug.sh
```

---

## 7. What the uninstaller does NOT do

If you want the host fully clean of every related package, do these
manually after the uninstaller runs:

```bash
# Debian/Ubuntu
sudo apt-get remove --purge -y nginx debmirror docker-registry
sudo npm uninstall -g verdaccio
sudo rm -rf /opt/mirroret-pypiserver /opt/mirroret-apt-mirror2 # if --pip / --apt was skipped

# RHEL family
sudo dnf remove -y nginx docker-distribution podman createrepo_c
sudo npm uninstall -g verdaccio
```

The uninstaller flags any leftover OS-package paths in its `[skip]`
output so you can decide.

---

## 8. Rollback vs uninstall

`./install.sh --rollback <backup-id>` is **not** the uninstaller - it
restores config files from a timestamped backup but leaves services,
data, and the directory tree in place. Use `--rollback` to undo a bad
install; use the uninstaller to leave the host clean.
