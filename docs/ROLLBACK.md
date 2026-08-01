# Rollback Guide

## Overview

mirroret creates timestamped backups before modifying any system file. If an installation goes wrong, you can restore the previous state.

Backups are stored in `/var/backups/mirroret/<timestamp>/`.

---

## Listing backups

```bash
sudo ./install.sh --list-backups
```

Example output:

```
  20260601-020000 (12 files)
  20260604-143022 (8 files)
```

---

## Rolling back

```bash
# Roll back to a specific backup:
sudo ./install.sh --rollback 20260601-020000
```

The rollback process:
1. Reads the backup manifest
2. Copies each backed-up file back to its original location
3. Skips files that did not exist at backup time (recorded as MISSING)
4. Attempts to reload affected services (nginx, pypiserver, verdaccio)
5. Reports how many files were restored, skipped, or failed

Rollback is **best-effort**. Individual failures are logged but do not abort the process.

---

## Creating a backup without installing

```bash
sudo ./install.sh --backup-only
```

This backs up all current config files without making any changes. Useful before manual edits.

---

## What is backed up

Before each installation run, the following files are backed up (if they exist):

- `/etc/apt/mirror.list`
- `/etc/nginx/sites-available/mirroret*`
- `/etc/nginx/conf.d/mirroret*.conf`
- `/etc/systemd/system/pypiserver.service`
- `/etc/systemd/system/verdaccio.service`
- `/etc/docker/registry/config.yml`
- `/etc/verdaccio/config.yaml`

---

## Manual backup

To back up a specific file manually:

```bash
cp /etc/nginx/conf.d/mirroret-unified.conf \
   /var/backups/mirroret/manual-$(date +%Y%m%d-%H%M%S)/etc/nginx/conf.d/mirroret-unified.conf
```

---

## Dry-run rollback

To preview what a rollback would do without making changes:

```bash
DRY_RUN=1 sudo ./install.sh --rollback 20260601-020000
```

---

## Backup directory structure

```
/var/backups/mirroret/
+-- 20260601-020000/
    +-- backup.manifest (list of OK/MISSING files)
    +-- etc/
        +-- apt/
        | +-- mirror.list
        +-- nginx/
        | +-- conf.d/
        | +-- mirroret-unified.conf
        +-- systemd/
        | +-- system/
        | +-- pypiserver.service
        | +-- verdaccio.service
        +-- verdaccio/
            +-- config.yaml
```

---

## After rollback

After a rollback you should:

1. Verify the restored configs:

   ```bash
   nginx -t
   systemctl status pypiserver
   systemctl status verdaccio
   ```

2. Run validation:

   ```bash
   sudo ./install.sh --check
   ```

3. Investigate the original failure before re-installing.
