# Quick Reference Card

## What does this server mirror?

```bash
mirroretctl targets            # every target + whether it has synced
mirroretctl client list        # generated client configs and their URLs
mirroretctl client verify      # configs vs what is actually published
```

Set it in `/etc/mirroret/mirroret.conf`, then `sudo mirroretctl upgrade`:

```bash
MIRRORET_APT_TARGETS="ubuntu:jammy ubuntu:noble debian:bookworm"
MIRRORET_RPM_TARGETS="ol:9 rocky:9 epel:9"
```

The mirror server's own distro is irrelevant - see [MULTI-DISTRO.md](MULTI-DISTRO.md).

## Most-used commands

| Task | Command | Root |
|---|---|---|
| Install / first-run wizard | `sudo ./install.sh` | yes |
| Apply a changed `/etc/mirroret/mirroret.conf` | `sudo mirroretctl upgrade` | yes |
| What is configured, has it synced | `mirroretctl targets` | no |
| Sync one ecosystem now | `sudo mirroretctl sync apt` (or `rpm`, `pip`, `npm`, `docker`, `all`) | yes |
| Is a sync running | `mirroretctl sync status` | no |
| Stop running syncs | `sudo mirroretctl sync stop` | yes |
| Integrity check after a sync | `mirroretctl verify` | no |
| On-demand cache health (hybrid/cache mode) | `mirroretctl cache status` | no |
| Services, ports, disk, cron | `mirroretctl status` | no |
| Full read-only diagnostic | `mirroretctl doctor` | no |
| One text file for support | `mirroretctl report` | no |
| Check generated client configs | `mirroretctl client verify` | no |
| Resolve + download as a client would | `mirroretctl client simulate` | no |
| Recent sync failures | `mirroretctl logs errors` | no |
| Config vs generated scripts | `mirroretctl config diff` | no |
| Approval queue | `mirroretctl approve list` | no |
| Promote staged packages | `sudo mirroretctl approve all rpm` | yes |
| Retention dry run / delete | `mirroretctl clean report` / `sudo mirroretctl clean prune` | no / yes |
| Validate the installation | `sudo mirroretctl check` | yes |
| Uninstall | `sudo mirroretctl uninstall --list` (preview) | yes |

`install.sh` symlinks `mirroretctl` into `/usr/local/bin`, so it is on `PATH`
after the first install. Before that, run `./mirroretctl` from the checkout.

## `mirroretctl help`

Output of `mirroretctl help`:

```
mirroretctl - control surface for a mirroret mirror server

Usage:
  mirroretctl                        interactive menu
  mirroretctl menu                   interactive menu (explicitly)
  mirroretctl <command> [args]

Inspect (no root needed):
  status                    services, ports, disk, last sync, cron
  targets                   which distributions this server mirrors, and
                            whether each one has actually synced
  targets show <file>       print one target spec from /etc/mirroret/targets
  doctor [--net] [--bundle] full read-only diagnostic
  report [-o FILE]          write ONE txt file describing everything, for sharing
  verify [--flavor F] [--suite S] [--json]
                            check every published Release: each file it lists
                            must be on disk with the right size
  cache status|routes|size  on-demand cache: daemon stats, route table, disk use
  sync status               which syncs are running, lock state
  sync last                 final line of the newest sync logs
  serve                     probe every HTTP endpoint locally
  approve list              packages staged and waiting for approval
  approve list rpm          full staged RPM file list
  client list               generated client configs and their URLs
  client show <file>        print one client config
  client verify             check client configs for breaking mistakes
  client simulate [pkg...]  act as a client: resolve AND download from the mirror
  logs list|tail|show|errors
  config show|path|diff
  clean report              retention dry run (default; read-only)
  service list              unit states

Change state (root):
  install [install.sh args] run the installer
  upgrade                   re-apply config, regenerate managed scripts
  check                     validate the installation
  uninstall [args]          run the uninstaller (see uninstall.sh --help)
  sync all|apt|rpm|pip|npm|docker
  sync stop                 stop running syncs
  approve all [pip|npm|rpm] promote staged packages (omit kind for all)
  approve pip|npm|rpm <n>   promote packages matching a name
  approve deny <kind> <n>   delete staged packages (decline them)
  clean prune               retention delete
  cache gc                  restart the cache daemon so a new size cap applies
  config edit               edit /etc/mirroret/mirroret.conf
  service start|stop|restart <unit>
  service logs <unit> [n]

Examples:
  mirroretctl status
  mirroretctl targets
  sudo mirroretctl sync apt
  sudo mirroretctl sync rpm
  mirroretctl clean report
  mirroretctl verify --flavor ubuntu
  mirroretctl cache status
  mirroretctl client verify
  mirroretctl serve
  mirroretctl approve list
  sudo mirroretctl approve all rpm

Approval mode (MIRRORET_APPROVAL_ENABLED=1) stages downloads instead of
serving them. Nothing reaches a client until you approve it.

Environment:
  MIRRORET_CONF   config file to read (default /etc/mirroret/mirroret.conf).
                  Handy for checking a staged config before applying it:
                    MIRRORET_CONF=/tmp/new.conf mirroretctl config diff
```

## Paths

| Path | Purpose |
|---|---|
| `/etc/mirroret/mirroret.conf` | operator configuration (wizard-written or copied from `config/mirroret.conf.example`) |
| `/etc/mirroret/targets/*.json` | generated target specs, one per distro release |
| `/etc/mirroret/cache.json` | generated cache route table (hybrid/cache mode) |
| `/srv/mirroret/apt/<flavor>/` | APT trees (`dists/` + `pool/`), served as `/<flavor>/` |
| `/srv/mirroret/redhat/mirror/<flavor>/<major>/<repo>/` | RPM trees, served as `/redhat/<flavor>/<major>/<repo>/` |
| `/srv/mirroret/config/` | generated client configs, served as `/config/` |
| `/srv/mirroret/scripts/` | generated sync scripts (`sync-all.sh`, `sync-apt-repos.sh`, ...) |
| `/srv/mirroret/logs/` | one timestamped log per sync run |
| `/var/log/mirroret-install.log` | installer log |
| `/etc/logrotate.d/mirroret` | managed log rotation |
