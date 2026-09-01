# Rollback

`install.sh` backs up every system file it is about to modify into
`${MIRRORET_BACKUP_BASE}/<backup-id>/` (default `/var/backups/mirroret/`)
before writing. `--rollback` copies those files back.

Rollback restores **configuration files** only. It does not touch mirror
data, remove services or delete directories; for that use the uninstaller
([UNINSTALL.md](UNINSTALL.md)).

---

## Listing backups

```bash
sudo ./install.sh --list-backups
```

One line per backup id (`YYYYMMDD-HHMMSS`) with the number of manifest
entries.

## Rolling back

```bash
sudo ./install.sh --rollback 20260601-020000
```

The rollback:

1. reads `backup.manifest` in the backup directory;
2. copies each `OK` entry back to its original path;
3. skips entries recorded as `MISSING` (the file did not exist at backup time);
4. runs `systemctl daemon-reload`, then reloads (or restarts) nginx and
   restarts `pypiserver` and `verdaccio`;
5. reports restored / skipped / failed counts.

Individual failures are logged and do not abort the run. Preview with
`sudo DRY_RUN=1 ./install.sh --rollback <id>`.

## Backup without installing

```bash
sudo ./install.sh --backup-only
```

## What is backed up

At the start of every install / `--upgrade` run (`_backup_existing_configs`
in `install.sh`):

- `/etc/apt/mirror.list`
- `/etc/nginx/sites-available/mirroret-unified`, `/etc/nginx/sites-available/mirroret`
- `/etc/nginx/conf.d/mirroret-unified.conf`, `/etc/nginx/conf.d/mirroret.conf`
- `/etc/systemd/system/pypiserver.service`
- `/etc/systemd/system/verdaccio.service`
- `/etc/docker/registry/config.yml`
- `/etc/docker-distribution/registry/config.yml`
- `/etc/verdaccio/config.yaml`

In addition, `lib/nginx.sh` backs up the vhost file (and its
`sites-enabled` symlink on Debian) immediately before rewriting it, and
rolls back to the same backup automatically if `nginx -t` fails after the
write.

Not backed up, because they are regenerated from `/etc/mirroret/mirroret.conf`
on every run: target specs (`/etc/mirroret/targets/`), `cache.json`, the
sync scripts under `/srv/mirroret/scripts/`, client configs under
`/srv/mirroret/config/`, the cron block and `/etc/logrotate.d/mirroret`.
Re-running `sudo ./install.sh --upgrade` recreates them.

## Layout

```
/var/backups/mirroret/
+-- 20260601-020000/
    +-- backup.manifest          one "OK <path>" or "MISSING <path>" per line
    +-- etc/
        +-- nginx/conf.d/mirroret-unified.conf
        +-- systemd/system/pypiserver.service
        +-- systemd/system/verdaccio.service
        +-- verdaccio/config.yaml
        ...
```

## After a rollback

```bash
sudo nginx -t
systemctl status nginx pypiserver verdaccio
sudo ./install.sh --check
```

Then find out why the install that was rolled back failed
(`/var/log/mirroret-install.log`, `mirroretctl doctor`) before re-running it.
