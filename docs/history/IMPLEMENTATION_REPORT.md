> Historical snapshot (2026-06). Describes an earlier version; see README.md for current behaviour.

# Implementation Report

**Date:** 2026-06-04
**Scope:** Deep review and refactor of mirroret v1.5.2

---

## What was done

### Phase 1: Deep review

Produced `docs/DEEP_REVIEW.md` with 30 findings across 4 severity levels:

- 4 Critical (security defaults that expose clients to package injection)
- 10 High (shell safety, missing rollback, privilege issues)
- 15 Medium (idempotency, hardcoded values, incomplete sync)
- ~10 Low (minor quality issues)

### Phase 2: Refactor

Created `lib/` directory with 14 focused modules:

| File | Purpose |
|------|---------|
| `lib/logging.sh` | Structured logging: info/warn/error/success/debug/die/warn_insecure |
| `lib/common.sh` | DRY_RUN, xrun(), write_file(), atomic_write(), idempotency helpers |
| `lib/distro.sh` | Distro detection, ubuntu_codename(), SELinux context handling |
| `lib/preflight.sh` | Root check, disk space, write permissions, network tools |
| `lib/backup.sh` | Timestamped backups, list_backups(), rollback() |
| `lib/nginx.sh` | nginx config generation with pre-write validation, backup, atomic write |
| `lib/systemd.sh` | Unit file management, deferred daemon-reload, idempotent enable/start |
| `lib/firewall.sh` | ufw/firewalld/iptables with optional source CIDR restriction |
| `lib/apt.sh` | apt-mirror config, APT client config with GPG/insecure modes |
| `lib/rpm.sh` | createrepo sync script, RPM client config with GPG/insecure modes |
| `lib/docker_registry.sh` | Docker registry with idempotent container management, TLS/insecure modes |
| `lib/pip.sh` | pypiserver in virtualenv as unprivileged user, hardened systemd unit |
| `lib/npm.sh` | Verdaccio as unprivileged user, htpasswd created, npm pack for sync |
| `lib/validation.sh` | --check/--status/--validate implementation |

Created `install.sh` as the unified orchestrator with:
- `set -Eeuo pipefail` throughout
- `trap ... ERR` for error reporting
- Full argument parsing: `--dry-run`, `--config`, `--check`, `--status`, `--rollback`, `--list-backups`, `--backup-only`, `--no-*`, `--insecure`, `--non-interactive`, `--debug`
- All insecure modes gated behind explicit flags
- Distro-aware (skips APT on RHEL, skips RPM on Debian)

### Phase 3: Security fixes

| Issue | Before | After |
|-------|--------|-------|
| APT `trusted=yes` | Default in all client configs | Requires `MIRRORET_APT_INSECURE=1` explicitly; default is GPG or placeholder |
| RPM `gpgcheck=0` | Default in all client configs | `gpgcheck=1` default; insecure requires `MIRRORET_RPM_INSECURE=1` |
| Docker insecure-registries | Default in docker-daemon.json | Only with `MIRRORET_DOCKER_INSECURE=1`; default uses TLS URL |
| pip trusted-host | Default in pip.conf | Only with `MIRRORET_PIP_INSECURE=1`; default uses https |
| All insecure modes | Silent | Print `warn_insecure()` banner with `!!!` borders, written to log |
| pypiserver user | `User=root` | Dedicated `mirroret-pip` system user, hardened unit |
| verdaccio user | `User=root` | Dedicated `mirroret-npm` system user, hardened unit |
| nginx config overwrite | No backup | `backup_file()` called before every write |
| nginx -t | After config written | Pre-validated in tmpfile; `atomic_write` only on success |
| Docker container | Unconditional `docker run` | Checks existing/running container first (idempotent) |
| pip install | `--break-system-packages` | Uses virtualenv at `/opt/mirroret-pypiserver` |

### Phase 4: Rollback and backups

- `lib/backup.sh` implements timestamped backup at `/var/backups/mirroret/<timestamp>/`
- Backs up: nginx configs, systemd units, docker registry config, verdaccio config, apt mirror.list, sync scripts
- `--rollback <id>` restores all files and reloads affected services
- `--backup-only` backs up current state without installing
- `--list-backups` shows available backups with file counts
- Rollback is best-effort: individual failures are logged but don't abort

### Phase 5: Validation

`install.sh --check` runs `run_validation()` from `lib/validation.sh` which checks:
- Required commands present
- Distribution detected
- Disk space
- Directory structure
- nginx config syntax and service state
- pypiserver/verdaccio service state
- APT Packages.gz metadata
- RPM repomd.xml metadata
- Client config files present

`install.sh --status` prints a quick service overview with disk usage.

### Phase 6: Tests and linting

- `tests/test_distro.bats` - 11 tests for distro detection and codename logic
- `tests/test_config.bats` - 8 tests for DRY_RUN, backup, config parsing
- `tests/test_security.bats` - 11 tests for insecure mode defaults and warnings
- `tests/test_dryrun.bats` - 6 tests for dry-run behaviour

**Test results: 36/36 passing.**

- `Makefile` with `lint`, `format`, `test`, `validate`, `dry-run`, `check-deps` targets
- `make lint` runs shellcheck on all lib/ files and install.sh
- shellcheck exits 0 with `--severity=warning` on all files

### Phase 7: Documentation

| File | Status |
|------|--------|
| `README.md` | Rewritten - accurate quick-start, no "enterprise-ready" claims |
| `docs/SECURITY.md` | New - GPG setup, TLS config, auth, privilege |
| `docs/CONFIGURATION.md` | New - full variable reference table |
| `docs/OPERATIONS.md` | New - daily ops, sync, disk management |
| `docs/ROLLBACK.md` | New - backup and rollback procedures |
| `docs/TROUBLESHOOTING.md` | Replaced TROUBLESHOOTING-GUIDE.md - matches actual implementation |
| `docs/DEEP_REVIEW.md` | New - full technical security review |

Removed misleading claims ("enterprise-ready", "production-ready") from README.md. Added honest limitations section.

---

## Files touched

**New files (29):**
- `install.sh`
- `Makefile`
- `config/mirroret.conf.example`
- `lib/logging.sh`, `lib/common.sh`, `lib/distro.sh`, `lib/preflight.sh`
- `lib/backup.sh`, `lib/nginx.sh`, `lib/systemd.sh`, `lib/firewall.sh`
- `lib/apt.sh`, `lib/rpm.sh`, `lib/docker_registry.sh`, `lib/pip.sh`, `lib/npm.sh`
- `lib/validation.sh`
- `tests/test_helpers.bash`, `tests/test_distro.bats`, `tests/test_config.bats`
- `tests/test_security.bats`, `tests/test_dryrun.bats`
- `docs/DEEP_REVIEW.md`, `docs/SECURITY.md`, `docs/CONFIGURATION.md`
- `docs/OPERATIONS.md`, `docs/ROLLBACK.md`, `docs/TROUBLESHOOTING.md`
- `docs/IMPLEMENTATION_REPORT.md`

**Modified files (1):**
- `README.md` - rewritten

**Preserved unchanged:**
- `mirroret.sh` - original basic installer kept for reference
- `mirroret-unified.sh` - original unified installer kept for reference
- All original `*.md` docs - kept for historical reference (superseded by `docs/`)

---

## Security improvements

| Before | After |
|--------|-------|
| All client configs allow unauthenticated packages | Secure by default; insecure requires explicit opt-in |
| All insecure modes silent | Loud `warn_insecure()` banners written to stdout and log |
| Services run as root | Dedicated system users with hardened systemd units |
| No backup before system changes | Timestamped backups before every system file write |
| nginx config overwrites existing without validation | Validated in tmpfile, atomic write only on success |
| Docker container launched unconditionally | Idempotent: checks state before creating/starting |
| pip installed with --break-system-packages | Isolated virtualenv |
| verdaccio htpasswd missing (service fails to start) | Empty htpasswd created during setup |
| No rollback path | Full `--rollback <id>` implementation |

---

## Remaining limitations

These are known limitations that are documented but not fully solved in this implementation:

1. **No built-in TLS termination.** nginx, pypiserver, and the Docker registry serve over plain HTTP by default. TLS should be configured with a reverse proxy (nginx itself can do it, docs/SECURITY.md has guidance). The new install.sh generates configs that reference HTTPS endpoints where possible, but server-side TLS setup requires a certificate.

2. **GPG signing is scaffolded, not automated.** The installer generates the right client configs when `MIRRORET_APT_KEYRING` and `MIRRORET_RPM_GPGKEY_URL` are provided, but the GPG key generation and repository signing workflow is documented only (docs/SECURITY.md), not automated.

3. **SELinux handling is best-effort.** On RHEL with enforcing SELinux, `semanage` and `restorecon` are called if available, with a warning if not. This may still require manual intervention on locked-down systems.

4. **Docker sync script pushes to registry but doesn't push.** Wait - this was FIXED: the new `write_docker_sync_script` in docker_registry.sh now includes `docker push` after `docker tag`. But the sync is still triggered manually; no automatic push approval workflow exists.

5. **npm sync uses `npm pack` (downloads tarballs) but doesn't auto-publish.** The script downloads tarballs to a staging directory and prints the command to publish them. A fully automated npm mirroring workflow would require additional tooling (e.g., `verdaccio-mirroring-plugin`).

6. **apt-mirror mirrors full Ubuntu distribution** - hundreds of GB. Operators should tune `mirror.list` for their actual needs. The config now uses configurable codename/arch.

7. **The original `mirroret.sh` and `mirroret-unified.sh`** still have all their original issues and are preserved unchanged. They are superseded by `install.sh` but not removed to avoid breaking any existing automation.

---

## Manual testing steps

After installing the dependencies (`apt-get install shellcheck bats`):

```bash
# Lint check (must exit 0):
make lint

# Run tests (must show 36/36 ok):
make test

# Dry-run preview (must show DRY-RUN lines, exit 0 or 1 for root):
bash install.sh --dry-run --non-interactive --no-firewall 2>&1 | head -40

# Help output:
bash install.sh --help

# List backups (empty system, must exit 0):
bash install.sh --list-backups

# Validate (requires root, will show missing dirs etc.):
sudo bash install.sh --check
```

To test a full installation in a clean VM:

```bash
# Lab mode (air-gapped, no GPG):
sudo ./install.sh --insecure

# Standard mode (generates placeholder configs until GPG configured):
sudo ./install.sh

# APT-only:
sudo ./install.sh --no-rpm --no-pip --no-docker --no-npm

# After installation, validate:
sudo ./install.sh --check

# Test rollback:
sudo ./install.sh --list-backups
sudo ./install.sh --rollback <backup-id>
```

---

## Commands to run next

```bash
# 1. Check all tools are available:
make check-deps

# 2. Run lint and tests:
make lint && make test

# 3. Install on a test machine:
sudo ./install.sh --dry-run # preview first
sudo ./install.sh --insecure # lab mode

# 4. For production hardening:
# a. Generate a GPG key (see docs/SECURITY.md)
# b. Configure MIRRORET_APT_KEYRING and MIRRORET_RPM_GPGKEY_URL
# c. Set up TLS on nginx for the registry proxy
# d. Set MIRRORET_FIREWALL_SOURCE to restrict client access
# e. Re-run: sudo ./install.sh --config /etc/mirroret/mirroret.conf
```
