# Retention and Upgrades

## What retention does and does not touch

| Tree | Pruned by retention? | How growth is controlled |
|---|---|---|
| APT (`apt/<flavor>/`) | **No** | `MIRRORET_APT_DELETE=1` (default): the sync removes exactly what upstream stopped listing |
| RPM (`redhat/mirror/`) | Yes, `MIRRORET_RPM_KEEP_VERSIONS` | plus `MIRRORET_RPM_NEWEST_ONLY=1` (default), which already keeps one build per package |
| pip | Yes, `MIRRORET_PIP_KEEP_VERSIONS` | - |
| npm | Yes, `MIRRORET_NPM_KEEP_DAYS` | - |
| Docker | Optional, `MIRRORET_DOCKER_GC=1` | - |

**The APT tree is deliberately excluded, and must stay excluded.** An apt
archive is a closed set: every `.deb` in `pool/` is referenced by a
`Packages` index that is hashed by a signed `Release`. Deleting "old
versions" out of the pool leaves the index pointing at files that no longer
exist, and every client then fails mid-download. Growth is controlled the
correct way instead - the sync deletes what upstream deleted, so the mirror
tracks upstream rather than accumulating.

If an APT mirror is bigger than you want, the lever is scope, not deletion:

```bash
MIRRORET_APT_COMPONENTS="main restricted"   # ~90% smaller than all four
MIRRORET_APT_TARGETS="ubuntu:noble"         # drop releases you do not serve
```

**RPM retention is normally a no-op.** With `MIRRORET_RPM_NEWEST_ONLY=1`
(the default) only one build per package is ever mirrored, so
keep-versions has nothing to trim. It becomes meaningful only if you set
`MIRRORET_RPM_NEWEST_ONLY=0` to keep version history.


Two operational concerns that live together: keeping mirror disk usage
bounded (retention) and updating mirroret itself without breaking a
live install (upgrade safety).

---

## 1. Retention (mirror cleanup)

### The default: keep everything forever

Retention is **off** by default. That's the right choice for most mirror
operators - old package versions are the rollback path. Enable retention
only when you're confident disk pressure justifies it.

### How to enable

Add to `/etc/mirroret/mirroret.conf`:

```bash
MIRRORET_RETENTION_ENABLE=1
MIRRORET_RETENTION_MODE=report # start here - dry-run
MIRRORET_RPM_KEEP_VERSIONS=3 # keep 3 newest of each RPM
MIRRORET_PIP_KEEP_VERSIONS=3 # keep 3 newest wheels per package
MIRRORET_NPM_KEEP_DAYS=180 # drop npm tarballs older than 6 months
MIRRORET_DOCKER_GC=0 # 1 = weekly registry garbage-collect
```

Then run a dry-run to see what would be removed:

```bash
sudo ./install.sh --cleanup-report
```

Read the output. If you're happy, flip to `prune`:

```bash
sudo sed -i 's/^MIRRORET_RETENTION_MODE=.*/MIRRORET_RETENTION_MODE=prune/' \
    /etc/mirroret/mirroret.conf
```

The next cleanup pass (weekly cron OR `sudo ./install.sh --cleanup`)
will delete for real.

### What happens per ecosystem

| Ecosystem | What retention does |
|---|---|
| **RPM** | `repomanage --keep=N --old` picks the RPMs to remove per package. After deletion `createrepo_c --update` refreshes `repomd.xml`. |
| **pip** | For each package name, keep the N newest wheels/sdists (sorted by mtime). Older versions are `rm`'d. |
| **npm** | Drop `.tgz` files under `npm/approved/` older than N days. Verdaccio's uplink cache is untouched. |
| **Docker** | Run `registry garbage-collect` on the registry's config. Requires briefly stopping the registry service (a few seconds of downtime). Off by default. |

### Modes

- `MIRRORET_RETENTION_MODE=report` - logs `[report]` lines and a summary of what *would* be removed. **No files are deleted.** Safe to run.
- `MIRRORET_RETENTION_MODE=prune` - actually deletes.

Any other value collapses to `report`. The retention library never errors out on individual failures - it warns and continues.

### CLI

```bash
sudo ./install.sh --cleanup-report # dry-run
sudo ./install.sh --cleanup # real run (honors MODE)
```

Both are equivalent to invoking `/srv/mirroret/scripts/cleanup-all.sh`
directly.

### Cron

install.sh installs a weekly cron entry alongside the daily sync:

```
# >>> mirroret managed (do not edit between markers) >>>
0 2 * * * /srv/mirroret/scripts/sync-all.sh
0 3 * * 0 /srv/mirroret/scripts/cleanup-all.sh
# <<< mirroret managed <<<
```

Cleanup runs Sundays at 03:00 by default. Change the timing with
`MIRRORET_CLEANUP_HOUR` and `MIRRORET_CLEANUP_DOW`. Then re-run
`./install.sh` to refresh the crontab.

### Watching disk

```bash
sudo du -sh /srv/mirroret/*
sudo /srv/mirroret/scripts/cleanup-all.sh # manual pass in report or prune mode
```

Or add your own alerting cron:

```bash
0 6 * * * df -h /srv/mirroret | awk 'NR==2 && $5+0 > 80 { print "warn" }' | \
    mail -s "mirror disk" ops@example
```

### What retention does NOT do

- It doesn't touch `/srv/mirroret/logs/`. Add your own logrotate config for that.
- It doesn't garbage-collect Verdaccio's uplink cache under `/verdaccio/storage/.cache/`. That's Verdaccio-internal state.
- It doesn't remove backup snapshots under `/var/backups/mirroret/`. Prune those manually.
- It doesn't check integrity - after a prune, `dnf repolist` etc. work because we refresh metadata, but no crypto verification is done.

---

## 2. Upgrade safety

### The problem

Every `sudo ./install.sh` regenerates:

- nginx vhost config
- systemd unit files
- verdaccio config
- pypiserver service unit
- `sync-*-packages.sh` scripts under `/srv/mirroret/scripts/`
- master `sync-all.sh` and `cleanup-all.sh`

If you edited any of those between installs - say, to add more packages
to the pip sync list - a naive install run would silently clobber your
edits. Bad.

### The mechanism

Every generated script mirroret writes carries a sentinel line near
the top:

```bash
#!/usr/bin/env bash
set -Eeuo pipefail
# MIRRORET-MANAGED: regenerated by install.sh. To customize the
# package list, use MIRRORET_*_PACKAGES_FILE (see docs/CONFIGURATION.md).
```

On every subsequent install:

1. Before overwriting, install.sh checks whether the existing file still
   contains the sentinel.
2. If it does -> operator hasn't touched it -> safe to regenerate.
3. If it doesn't -> operator has replaced or heavily edited the file ->
   install prints:
   ```
   WARN Preserving your customized /srv/mirroret/scripts/sync-pip-packages.sh
   ```
   and skips regeneration.

That way you can drop the sentinel line from a file you've customized,
and mirroret will leave your version alone forever.

Config files (nginx, verdaccio, systemd units) are always regenerated
but always backed up first - you can recover from
`/var/backups/mirroret/<timestamp>/`. Only the generated scripts under
`/srv/mirroret/scripts/` are subject to the sentinel check.

### The recommended way to customize

Prefer environment variables over editing generated files. See
`config/mirroret.conf.example` for the full list. For pip and npm
package lists:

```bash
sudo mkdir -p /etc/mirroret
sudo tee /etc/mirroret/pip-packages.txt <<'EOF'
requests
flask
django
# add whatever you need - one per line, # for comments
your-internal-package==1.2.3
EOF

sudo tee -a /etc/mirroret/mirroret.conf <<'EOF'
MIRRORET_PIP_PACKAGES_FILE=/etc/mirroret/pip-packages.txt
EOF

# Re-install (safely; sync scripts get regenerated with your new list):
sudo ./install.sh --upgrade
```

This gives you the same result as editing the sync script directly, but
survives every future upgrade.

### The `--upgrade` fast path

```bash
sudo ./install.sh --upgrade
```

Does everything a regular install does, minus the slow / already-done
pieces:

- Skips `install_system_packages` - assumes packages are current
- Skips directory creation - assumes `/srv/mirroret/` exists
- Skips `useradd` - assumes `mirroret-pip` / `mirroret-npm` exist
- Still regenerates configs (nginx, systemd units, verdaccio.yaml)
- Still regenerates managed scripts (respecting the sentinel)
- Still refreshes the cron block
- Still runs the SELinux relabel

Typical `--upgrade` takes ~10 seconds vs ~60 seconds for a full install.

### The upgrade workflow

```bash
cd ~/mirroret-main
git fetch origin
git reset --hard origin/main # or git pull --ff-only

# Optional: preview the differences first
sudo ./install.sh --upgrade --dry-run

# Real upgrade
sudo ./install.sh --upgrade

# Verify
sudo ./scripts/mirroret-debug.sh
```

### What `--upgrade` does NOT do

- Doesn't upgrade the OS packages you rely on (nginx, podman, nodejs).
  Do those separately with `dnf upgrade`.
- Doesn't run any sync. Trigger manually via `/srv/mirroret/scripts/sync-all.sh` if needed.
- Doesn't run retention. Use `--cleanup` for that.

### Sanity check: your data is always safe

`install.sh` - with or without `--upgrade` - **never touches**:

- `/srv/mirroret/` mirror data (RPMs, wheels, tarballs, Docker blobs)
- `/var/backups/mirroret/` snapshots
- `/etc/mirroret/gnupg/` signing key
- `/etc/mirroret/tls/` certificates

Only the uninstaller with `--purge` deletes these, and only after
explicit confirmation.

---

## 3. Common questions

**Will retention delete a package that's still in use by a client?**
It only sees your local files. If a client is currently installing an
older version and you prune it mid-install, the client's pull will 404
mid-transfer. Schedule cleanup during low-traffic windows.

**What if I set MIRRORET_RPM_KEEP_VERSIONS=0?**
Disabled - RPM retention is skipped entirely. Same for PIP=0 and
NPM_KEEP_DAYS=0.

**What if repomanage is missing?**
The RPM retention step warns and skips. Install `dnf-utils` to enable.

**Does `--upgrade` restart services?**
Only if a regenerated config differs from what was on disk (via
`nginx -t` reload for nginx, `systemctl daemon-reload` + restart for
units). Otherwise services keep running untouched.

**How do I roll back an --upgrade?**
Backups are still taken. `sudo ./install.sh --list-backups` and
`--rollback <id>` work the same as after a full install.
