> Historical snapshot (2026-06). Describes an earlier version; see README.md for current behaviour.

# MIRRORET Deep Technical Review

**Date:** 2026-06-04
**Scope:** mirroret.sh, mirroret-unified.sh, all documentation
**Version reviewed:** 1.5.2

---

## Architecture Overview

Two monolithic installer scripts (~1000 lines each) that:
1. Detect the host distro
2. Install system packages (nginx, apt-mirror, createrepo, docker, pypiserver, verdaccio)
3. Write config files for all components
4. Generate secondary scripts into `/var/mirroret/scripts/` or `/srv/localrepo/scripts/`
5. Register a cron job for daily sync
6. Open firewall ports

The two scripts diverged from a common ancestor and now partially duplicate each other. The basic script (`mirroret.sh`) targets APT/RPM only; the unified script adds pip, Docker, and npm.

---

## Findings

### CRITICAL

**C-1: APT client config uses `trusted=yes` unconditionally**
File: `mirroret.sh:554-556`, `mirroret-unified.sh:727-729`
The generated `localrepo.list` instructs client machines to skip all signature verification for every package served from this mirror. A compromised mirror server, a MITM, or a rogue admin could install arbitrary packages on every client without any cryptographic check.
Fix: Remove `trusted=yes`. Add a real GPG keyring to the mirror. If unsigned mode is needed for lab use, make it opt-in behind an explicit `--allow-insecure` flag with a loud warning.

**C-2: RPM client config sets `gpgcheck=0` unconditionally**
File: `mirroret.sh:570-583`, `mirroret-unified.sh:737-747`
Same severity as C-1. All RPM clients are instructed to skip GPG verification for every installed package.
Fix: Set `gpgcheck=1` and provide `gpgkey=` pointing to the repo's signing key. Insecure mode must be explicit and warned.

**C-3: Docker daemon insecure-registries pushed as default production config**
File: `mirroret-unified.sh:762-766`
The generated `docker-daemon.json` adds the registry to `insecure-registries` and `registry-mirrors` over plain HTTP. This disables TLS verification for all image pulls from this registry on every client. There is no warning about this in the generated config or documentation.
Fix: TLS should be the default. Insecure mode requires an explicit `--insecure-registry` flag and a warning banner.

**C-4: pip client config sets `trusted-host` unconditionally**
File: `mirroret-unified.sh:753-754`
The generated `pip.conf` disables certificate verification for the mirror host. Any MITM between the client and the server can inject malicious packages.
Fix: Remove `trusted-host`. Default to HTTPS or require explicit opt-in for plain HTTP.

---

### HIGH

**H-1: `set -e` without `set -u`, `set -o pipefail`, or `set -E`**
Files: `mirroret.sh:10`, `mirroret-unified.sh:10`
`set -e` alone does not catch unset variable expansions or failures in the left-hand side of a pipeline. A failed intermediate command silently succeeds. Example: `reposync ... 2>&1 | tee log` will succeed even if `reposync` exits non-zero.
Fix: Use `set -Eeuo pipefail` throughout. Propagate `ERR` to subshells and functions with `set -E`.

**H-2: No nginx config backup before overwrite**
Files: `mirroret.sh:248-311`, `mirroret-unified.sh:529-601`
The script overwrites `/etc/nginx/sites-available/mirroret` and `/etc/nginx/conf.d/mirroret.conf` without backing up the existing file. Re-running the script destroys any manual customizations silently.
Fix: Before writing any system config file, copy the existing file to a timestamped backup under `/var/backups/mirroret/`.

**H-3: nginx `-t` test is run after writing a potentially broken config**
Files: `mirroret.sh:315`, `mirroret-unified.sh:597`
`nginx -t` is called after the new config is already written to disk. If the test fails (e.g., due to a conflict with an existing vhost), `set -e` will abort but nginx is already broken on disk. The restart that follows would also fail.
Fix: Write config to a temp file, validate with `nginx -t -c <tmpfile>`, then atomically move into place only on success.

**H-4: No rollback mechanism for any system change**
Files: both scripts
If the installation fails midway (e.g., after nginx is restarted but before systemd services are configured), there is no way to restore the system to a known-good state. The only recovery path is manual.
Fix: Implement timestamped backups before each system-modifying step and a `--rollback <backup_id>` command.

**H-5: pypiserver and verdaccio systemd units run as root**
Files: `mirroret-unified.sh:295-302`, `mirroret-unified.sh:470-479`
Both services are configured with `User=root`. If pypiserver or verdaccio has a vulnerability, an attacker gains root access.
Fix: Create dedicated system users (`mirroret-pip`, `mirroret-npm`) and run services as those users with minimal filesystem permissions.

**H-6: Docker registry container launched with no existence check**
File: `mirroret-unified.sh:381-387`
`docker run` is called unconditionally. Re-running the script will fail with "container name already in use". The failure propagates through `set -e` and aborts the entire installation.
Fix: Check if the container exists (`docker ps -a --filter name=local-docker-registry`) before running. If it exists and is stopped, start it. If running, skip.

**H-7: Log file redirect before root check and before log directory exists**
Files: `mirroret.sh:27`, `mirroret-unified.sh:33`
`exec > >(tee -a "$LOG_FILE") 2>&1` runs before the root check. If the log directory doesn't exist or the user lacks permission, the script fails before printing a useful error message.
Fix: Create the log directory first, check for root, then redirect.

**H-8: RHEL `configure_createrepo` runs on all distros in unified script**
File: `mirroret-unified.sh:1009`
`configure_createrepo` is called unconditionally in `main()`, even on Debian/Ubuntu where `reposync` is not installed. This will fail silently or error out.
Fix: Gate behind `if [ "$DISTRO_TYPE" = "rhel" ]`.

**H-9: pip install uses `--break-system-packages` without a fallback strategy**
File: `mirroret-unified.sh:285-286`
The `--break-system-packages` flag bypasses PEP 668 protections intentionally. This can corrupt the system Python environment on newer distros.
Fix: Use a virtualenv or install pypiserver via the distro package manager where available.

**H-10: Firewall ports opened without user confirmation or scope control**
Files: `mirroret.sh:642-655`, `mirroret-unified.sh:776-795`
All ports are opened globally (any source). There is no prompt asking whether to restrict by source IP. In a production environment, repository access should be restricted to known client subnets.
Fix: Add `--firewall-source <CIDR>` option. Default to prompting, not silently opening.

---

### MEDIUM

**M-1: `hostname -I` is fragile for SERVER_IP**
Files: `mirroret.sh:23`, `mirroret-unified.sh:29`
`hostname -I | awk '{print $1}'` returns the first IP from the kernel's interface list. On multi-homed servers, VMs with management interfaces, or systems with VPN interfaces, this may return an internal/wrong IP. The generated client configs will point at the wrong address.
Fix: Allow `SERVER_IP` to be overridden via environment variable or config file. Document clearly.

**M-2: Hardcoded Ubuntu Jammy (22.04) in apt-mirror config**
Files: `mirroret.sh:191-193`, `mirroret-unified.sh:221-223`
The generated `mirror.list` always mirrors Ubuntu 22.04 regardless of the operator's actual environment. An admin running on Ubuntu 24.04 (Noble) will still sync 22.04 packages.
Fix: Detect installed release, or make `UBUNTU_CODENAME` a configurable variable. Document the config file.

**M-3: Hardcoded Rocky Linux 9 in reposync config**
Files: `mirroret.sh:223-232`, `mirroret-unified.sh:257-261`
reposync is always pointed at Rocky Linux 9 repos. On RHEL 8 or CentOS Stream 8, this will download mismatched packages.
Fix: Detect the running major version and use it, or require operator to set `RHEL_VERSION` explicitly.

**M-4: apt-mirror config in mirroret.sh uses hardcoded `/var/mirroret/mirror` instead of `$REPO_BASE_DIR`**
File: `mirroret.sh:177`
The heredoc uses `'EOF'` (quoted, no variable expansion), so `$REPO_BASE_DIR` is never substituted. The config always points at `/var/mirroret/mirror` even if `REPO_BASE_DIR` is changed.
Fix: Use `EOF` (unquoted) and reference `$REPO_BASE_DIR` properly, or keep quoted but replace the literal path with the correct value.

**M-5: `clear` called in `main()` - destroys log output**
Files: `mirroret.sh:904`, `mirroret-unified.sh:982`
Calling `clear` at the start of `main()` clears the terminal, making it impossible for an operator monitoring the installation to see early output. Also pollutes any CI/automation output.
Fix: Remove `clear` calls. Print a header instead.

**M-6: No idempotency - re-running causes duplicate cron jobs and broken services**
Files: `setup_cron()` in both scripts
The cron deduplication pattern `grep -v "sync-mirror.sh"` removes the old job before adding the new one, which is correct for that step. However, other steps (package installation, nginx config, systemd reload, docker container) do not check for existing state and will either fail or create duplicates.
Fix: Add `is_installed()`, `is_configured()`, `service_is_running()` checks before each step.

**M-7: Docker image sync script sets `local_image` variable but never uses it**
File: `mirroret-unified.sh:415`
`local_image=$(echo "$image" | sed 's/:/-/g')` is assigned but the actual tag uses `"$LOCAL_REGISTRY/$image"`. The variable is dead code.
Fix: Remove the dead variable.

**M-8: Docker sync script pulls images but never pushes them to the local registry**
File: `mirroret-unified.sh:410-418`
Images are pulled and tagged with the local registry prefix, but `docker push` is never called. The local registry remains empty after the sync script runs.
Fix: Add `docker push "$LOCAL_REGISTRY/$image"` after the tag step.

**M-9: npm sync script uses `npm view` which does not download packages**
File: `mirroret-unified.sh:504-507`
`npm view` only queries the npm registry for metadata. It does not download or cache packages. The "sync" does nothing to populate the Verdaccio cache.
Fix: Use `npm pack <package>` to download tarballs, or pre-populate via `npm install` in a temp directory with the Verdaccio registry configured.

**M-10: Nginx config for RHEL copies from `sites-available` which may not be used**
File: `mirroret-unified.sh:592-594`
On RHEL the script first writes to `/etc/nginx/sites-available/unified-repo` (a Debian-ism), then copies it to `conf.d/`. On RHEL, `sites-available` does not exist by default, so nginx would not use the sites-available file. The copy is correct, but writing to a nonexistent path first is misleading.
Fix: For RHEL, write directly to `conf.d/`. For Debian, use the symlink pattern.

**M-11: No disk space check before mirror operations**
Files: both scripts
Full Ubuntu mirror requires 200-500 GB. The script starts without checking available disk space. On a full disk, `apt-mirror` will corrupt partial downloads.
Fix: Add a preflight disk space check with a configurable minimum threshold.

**M-12: SELinux not handled on RHEL-based systems**
Files: `mirroret.sh`, `mirroret-unified.sh`
On RHEL/CentOS/Fedora with SELinux enforcing, nginx serving from non-standard paths (`/var/mirroret`, `/srv/localrepo`) will be blocked. The script does not set the required `httpd_sys_content_t` context or handle booleans like `httpd_can_network_connect`.
Fix: After creating directories, run `semanage fcontext` and `restorecon` if SELinux is enforcing. Or at minimum, warn and document.

**M-13: `DEBIAN_FRONTEND` not set for non-interactive installs**
Files: both scripts
`apt-get install -y` without `DEBIAN_FRONTEND=noninteractive` may pause on package configuration prompts (e.g., postfix asking for mail relay config).
Fix: Export `DEBIAN_FRONTEND=noninteractive` before apt operations.

**M-14: Verdaccio htpasswd file missing**
File: `mirroret-unified.sh:444`
The Verdaccio config references `./htpasswd` for authentication, but this file is never created. Verdaccio will fail to start or run in a broken state.
Fix: Either create an empty htpasswd file, or document how to create it, or configure anonymous access explicitly.

**M-15: Two scripts use different base directories (`/var/mirroret` vs `/srv/localrepo`)**
Files: `mirroret.sh:20`, `mirroret-unified.sh:22`
The two scripts are not interchangeable. A user who runs one then the other will have data in two different locations. Documentation does not make this distinction clearly.
Fix: Unify under one default directory, configurable via a single variable.

---

### LOW

**L-1: `--no-install-recommends` not used in apt-get**
On a dedicated server, recommended packages add unnecessary bloat.

**L-2: `install_base_packages` for Debian does `apt-get update` but RHEL path does not**
File: `mirroret-unified.sh:109`
RHEL `dnf`/`yum` should also have its metadata refreshed before installing packages.

**L-3: Documentation claims "enterprise-ready" and "production-ready" repeatedly**
Files: `README.md`, `UNIFIED-README.md`, `DEPLOYMENT-CHECKLIST.md`
The implementation has multiple critical security defaults (C-1 through C-4) that make it explicitly not production-ready. These claims are misleading.

**L-4: `mail` command used in sync script without checking if it is installed**
File: `mirroret.sh:497`
`echo "Mirror sync completed" | mail -s "..." root` will silently fail if `mailutils` is not installed.

**L-5: Generated management scripts hardcode paths instead of sourcing config**
All generated scripts under `scripts/` hardcode `/var/mirroret` or `/srv/localrepo`. If the operator changes `REPO_BASE_DIR`, the generated scripts break.

**L-6: `crontab -` pattern runs as root without a dedicated service account**
Both sync and approval scripts are scheduled under root's crontab. A bug or exploit in any sync script gains root.

**L-7: `tree` command called without verifying it is installed**
File: `mirroret-unified.sh:195`
`tree -L 2 "$REPO_BASE_DIR" 2>/dev/null || ls -R` - the fallback to `ls -R` is fine but calling an unknown command without checking first is a minor issue.

**L-8: docker.io vs docker-ce inconsistency**
File: `mirroret-unified.sh:117`
`docker.io` is the Ubuntu universe package (older). Many users prefer `docker-ce` from Docker's official repo. This is not wrong but should be documented.

**L-9: No log rotation configured**
Sync logs in `/var/mirroret/logs/` or `/srv/localrepo/logs/` grow indefinitely. No logrotate config is generated.

**L-10: `dpkg-scanpackages` output written to root of approved dir**
File: `mirroret.sh:372-374`
`dpkg-scanpackages . /dev/null | gzip -9c > Packages.gz` writes to the current directory. `cd "$APPROVED_DIR"` before running is required. The script does this but it is fragile - a failure before the cd would write `Packages.gz` to an unexpected location.

---

## Summary Table

| ID | Severity | Area | Issue |
|------|----------|-------------------|-------|
| C-1 | Critical | APT security | trusted=yes by default |
| C-2 | Critical | RPM security | gpgcheck=0 by default |
| C-3 | Critical | Docker security | insecure-registries as default |
| C-4 | Critical | pip security | trusted-host disables cert check |
| H-1 | High | Shell safety | set -e only, no pipefail/nounset |
| H-2 | High | nginx | No backup before overwrite |
| H-3 | High | nginx | nginx -t after config written, not before |
| H-4 | High | Operations | No rollback mechanism |
| H-5 | High | Privilege | pypiserver/verdaccio run as root |
| H-6 | High | Docker | No existence check before docker run |
| H-7 | High | Logging | Log redirect before root check |
| H-8 | High | RHEL | configure_createrepo unconditional |
| H-9 | High | pip | --break-system-packages without fallback |
| H-10 | High | Firewall | Ports opened globally without prompt |
| M-1 | Medium | Config | hostname -I fragile on multi-homed hosts |
| M-2 | Medium | APT | Hardcoded Ubuntu Jammy |
| M-3 | Medium | RPM | Hardcoded Rocky Linux 9 |
| M-4 | Medium | APT | mirroret.sh apt-mirror path not using variable |
| M-5 | Medium | UX | clear() destroys log output |
| M-6 | Medium | Idempotency | Re-running breaks things |
| M-7 | Medium | Docker | Dead variable in sync script |
| M-8 | Medium | Docker | Images pulled but never pushed |
| M-9 | Medium | npm | npm view does not download packages |
| M-10 | Medium | nginx/RHEL | sites-available path doesn't exist on RHEL |
| M-11 | Medium | Preflight | No disk space check |
| M-12 | Medium | RHEL/SELinux | No SELinux context handling |
| M-13 | Medium | APT | DEBIAN_FRONTEND not set |
| M-14 | Medium | npm | Verdaccio htpasswd file missing |
| M-15 | Medium | Architecture | Two scripts use different base dirs |
| L-1 | Low | APT | No --no-install-recommends |
| L-2 | Low | RPM | No dnf/yum metadata refresh |
| L-3 | Low | Docs | Overstated production-readiness claims |
| L-4 | Low | Sync | mail command not checked |
| L-5 | Low | Generated scripts | Hardcoded paths in generated scripts |
| L-6 | Low | Privilege | Sync runs under root crontab |
| L-7 | Low | UX | tree not checked before call |
| L-8 | Low | Docker | docker.io vs docker-ce |
| L-9 | Low | Ops | No log rotation |
| L-10 | Low | APT | fragile cd + dpkg-scanpackages |
