> Site-specific notes: written for one particular deployment (hostnames, proxy addresses and blockers are that site's). Not general documentation; see README.md and docs/ for current behaviour.

# Deploy runbook

For the admin deploying mirroret to the mirror server.

Target: RHEL 9 host serving Oracle Linux 9 **and** Ubuntu/Debian clients,
behind an HTTP proxy that restricts which upstream hosts it will connect to.

The mirror server running RHEL does not limit what it can mirror. What it
serves is named in `MIRRORET_APT_TARGETS` / `MIRRORET_RPM_TARGETS` in Part 6.

Work through the parts in order. Each part ends with a verification step.
If a verification fails, stop and report it. Do not continue past a failed
STOP checkpoint.

---

## Part 0. What you need before starting

- SSH or console access to the mirror server, with sudo
- A machine that can reach github.com (your laptop)
- A contact on the proxy team. Part 3 identifies which upstream hosts are
  blocked; opening them is the one thing you cannot do yourself.
- The proxy address. In this environment: http://192.168.30.243:3128

---

## Part 1. Get the code onto the server

### 1a. On a machine WITH internet

```bash
curl -L -o mirroret.zip https://github.com/sarat1kyan/mirroret/archive/refs/heads/main.zip
```

Browser alternative: open https://github.com/sarat1kyan/mirroret,
click Code, then Download ZIP.

### 1b. Move it to the server

Pick whichever you have:

```bash
# scp
scp mirroret.zip serob@192.168.30.110:~/

# MobaXterm: drag mirroret.zip into the left-hand SFTP pane

# USB or shared drive: copy the file, then place it in the home dir
```

### 1c. On the server, extract

```bash
cd ~
```

Keep the previous tree until the new one is verified:

```bash
[ -d mirroret-main ] && mv mirroret-main mirroret-main.prev
unzip -o mirroret.zip
cd mirroret-main
```

A zip archive does not preserve the execute bit. Restore it or nothing
will run:

```bash
chmod +x install.sh uninstall.sh mirroretctl scripts/*.sh
```

### 1d. VERIFY the right version arrived

```bash
grep -c '_resolve_verdaccio_bin' lib/npm.sh
grep -c 'mirroret_script_preamble' lib/common.sh
grep -c 'logs|scripts|staging' lib/nginx.sh
ls -l mirroretctl
```

All three counts must be 1 or more. `mirroretctl` must show `-rwxr-xr-x`.

If any count is 0, the zip is stale or extracted partially. Re-download
and repeat 1a to 1c.

STOP if this fails.

---

## Part 2. Clear leftover state from the previous run

An earlier sync ran away downloading source RPMs. Stop anything still
running and reclaim the space.

```bash
sudo pkill -f reposync
sudo pkill -f 'sync-redhat-repos|sync-rpm-repos|sync-apt-repos'
sudo pkill -f 'mirroret_rpm.py|mirroret_apt.py'

sudo pkill -f sync-all
```

Count what is there before deleting:

```bash
sudo find /srv/mirroret/redhat -name '*.src.rpm' -type f 2>/dev/null | wc -l
```

Delete them:

```bash
sudo find /srv/mirroret/redhat -name '*.src.rpm' -type f -delete
sudo dnf clean all
sudo rm -rf /var/cache/dnf/*
```

The mirror server is RHEL but serves Oracle Linux. Its own RHEL tree is
roughly 130 GB and is not what the clients need. Check the size:

```bash
sudo du -sh /srv/mirroret/redhat/mirror/rhel 2>/dev/null
```

If you do not need to serve RHEL clients, reclaim it:

```bash
sudo rm -rf /srv/mirroret/redhat/mirror/rhel
```

### VERIFY

```bash
df -h /srv/mirroret
```

Note the free figure. You need roughly 60 to 90 GB for the four Oracle
Linux repos.

---

## Part 3. Proxy reachability (this is the blocker)

Some upstreams are refused by the proxy. Find out which before doing
anything else.

### 3a. Check whether TLS is being inspected

```bash
openssl s_client -connect yum.oracle.com:443 -proxy 192.168.30.243:3128 -showcerts </dev/null 2>/dev/null \
  | grep -E '^ *[0-9]+ s:|^ *i:'
```

If the issuers are public CAs (DigiCert, Sectigo, Let's Encrypt, and so
on) there is **no TLS inspection** and you need no certificate file.
Skip to 3b.

If an issuer carries your company name, you do have inspection: follow
docs/PROXY_AND_CA.md section 3 to install the corporate root CA, then
continue.

Do not copy a private key from the proxy under any circumstances.

### 3b. Find which hosts the proxy blocks

```bash
for h in \
  yum.oracle.com \
  cdn.redhat.com \
  dl.rockylinux.org \
  repo.almalinux.org \
  dl.fedoraproject.org \
  archive.ubuntu.com \
  security.ubuntu.com \
  deb.debian.org \
  pypi.org \
  files.pythonhosted.org \
  registry.npmjs.org \
  registry-1.docker.io \
  auth.docker.io ; do
    printf '%-32s %s\n' "$h" \
      "$(curl -sS -o /dev/null -w '%{http_code}' --max-time 10 "https://$h/" 2>/dev/null)"
done
```

Interpretation:

| Code | Meaning |
|---|---|
| 200 / 301 / 302 | reachable |
| 401 from registry-1.docker.io | reachable, this is expected |
| 000 | blocked by the proxy |

### 3c. Request an allow-list for anything showing 000

Send the proxy team the blocked hostnames and ask for CONNECT on port 443.

Two pairs are easy to get half-wrong:

* `files.pythonhosted.org` is required in addition to `pypi.org`. Wheels are
  served from it; allowing only pypi.org lets metadata through and fails
  every download.
* `security.ubuntu.com` is required in addition to `archive.ubuntu.com`.
  Ubuntu serves the `-security` suite from a different host, so allowing
  only the archive gets you a mirror with no security updates - which is
  the worst possible outcome to discover late.

The APT engine fetches over plain HTTP by default (the archives are
GPG-signed, so the transport is not what protects them). If your proxy only
permits CONNECT on 443, switch the scheme instead of asking for port 80:

```bash
echo 'MIRRORET_APT_SCHEME=https' | sudo tee -a /etc/mirroret/mirroret.conf
sudo ./install.sh --upgrade
```

### What you can do before the allow-list lands

If `yum.oracle.com` is reachable, the RPM mirror is the bulk of the data
and can sync now. Continue through the runbook, and at Part 9 run only what
is reachable:

```bash
sudo ./mirroretctl sync rpm      # if yum.oracle.com is reachable
sudo ./mirroretctl sync apt      # if archive.ubuntu.com is reachable
```

Leave pip and npm until their hosts are unblocked. To stop them failing
nightly in the meantime, install without them:

```bash
sudo ./install.sh --upgrade --no-pip --no-npm
```

STOP only if `yum.oracle.com` shows 000. Nothing can sync in that case.

---

## Part 4. Fix the clock

```bash
sudo timedatectl set-ntp true
sudo systemctl enable --now chronyd
sudo chronyc makestep
sleep 30
timedatectl | grep -E 'synchronized|Local time'
```

Required: `System clock synchronized: yes`.

If it stays `no`:

```bash
sudo chronyc sources -v
```

Look for a source prefixed `^*`. If there is none, the proxy is blocking
NTP on UDP 123. Ask IT for an internal NTP server, then:

```bash
echo "server INTERNAL-NTP-HOST iburst" | sudo tee -a /etc/chrony.conf
sudo systemctl restart chronyd
```

---

## Part 5. Oracle repo definitions on this host (OPTIONAL now)

**Skip this part unless you need this RHEL host to install Oracle packages
for itself.** Mirroring no longer reads Oracle's URLs from this host's dnf
configuration - mirroret's own catalog carries the literal hostnames, so
there are no `$ociregion`/`$ocidomain` variables to expand and no Oracle
release package to install.

Verify that is true for your build before skipping:

```bash
grep -o 'https://[^"]*' /etc/mirroret/targets/rpm-ol-9.json
```

Every URL must be literal, with no `$` in it. If the file does not exist
yet, that is fine - Part 7 creates it.

<details>
<summary>Only if this host must install Oracle packages itself</summary>

The file Oracle ships uses dnf variables that only exist when the
`oraclelinux-release-el9` package is installed. On a RHEL host they stay
literal, producing URLs like `https://yum$ociregion.$ocidomain/...`.

Note: a plain `sed` on that string does not work, because `$` is a regex
anchor. Replace the whole file.

```bash
sudo tee /etc/yum.repos.d/oracle-linux-ol9.repo >/dev/null <<'EOF'
[ol9_baseos_latest]
name=Oracle Linux 9 BaseOS Latest (x86_64)
baseurl=https://yum.oracle.com/repo/OracleLinux/OL9/baseos/latest/x86_64/
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-oracle
gpgcheck=1
enabled=1

[ol9_appstream]
name=Oracle Linux 9 Application Stream Packages (x86_64)
baseurl=https://yum.oracle.com/repo/OracleLinux/OL9/appstream/x86_64/
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-oracle
gpgcheck=1
enabled=1
EOF

sudo curl -fsSL -o /etc/pki/rpm-gpg/RPM-GPG-KEY-oracle \
    https://yum.oracle.com/RPM-GPG-KEY-oracle-ol9
sudo dnf clean all && sudo dnf makecache
grep baseurl /etc/yum.repos.d/oracle-linux-ol9.repo   # no $ may appear
```

</details>

---

## Part 6. Configure mirroret

```bash
sudo mkdir -p /etc/mirroret
sudo cp config/mirroret.conf.example /etc/mirroret/mirroret.conf
```

Append the settings for this environment. Change the proxy address and
the CA path if yours differ.

```bash
sudo tee -a /etc/mirroret/mirroret.conf >/dev/null <<'EOF'

# WHAT THE CLIENTS RUN. Nothing here depends on this host being RHEL.
# Trim or extend both lists to match your fleet.
MIRRORET_RPM_TARGETS="ol:9"
MIRRORET_APT_TARGETS="ubuntu:jammy ubuntu:noble debian:bookworm"

# Repos to take from each RPM target. Catalog ids, not dnf repo ids.
MIRRORET_RPM_REPOS="baseos appstream uek epel"

# Biggest disk lever on the APT side: universe and multiverse are most of
# an Ubuntu mirror. Drop this line to mirror all four components.
MIRRORET_APT_COMPONENTS="main restricted"

# Sync safety. Source RPMs are 400-600 MB each and there are ~44000 of
# them in appstream; leaving this at 0 is what keeps the disk sane.
MIRRORET_RPM_ARCH=x86_64
MIRRORET_RPM_NEWEST_ONLY=1
MIRRORET_RPM_SOURCE=0
MIRRORET_RPM_DELETE=1
MIRRORET_SYNC_MIN_FREE_GB=15
MIRRORET_SYNC_TIMEOUT=6h
MIRRORET_SYNC_ESTIMATE=1
MIRRORET_SYNC_SMOKE_TEST=1

# Proxy. Set here, not only in the shell: cron and systemd do not read
# /etc/environment or shell rc files.
http_proxy=http://192.168.30.243:3128
https_proxy=http://192.168.30.243:3128
no_proxy=localhost,127.0.0.1,::1,10.0.0.0/8,192.168.0.0/16

# Corporate CA. Exported to pip, npm, node and curl by the generated
# sync scripts.
MIRRORET_CA_BUNDLE=/etc/pki/tls/cert.pem

# npm: pre-seeding needs no credentials any more (it warms Verdaccio's
# cache by installing through it), so anonymous publish stays OFF. Set it
# to 1 only if people will `npm publish` in-house packages here.
MIRRORET_NPM_ALLOW_ANON_PUBLISH=0

# Retention. Start in report mode, review, then switch to prune.
MIRRORET_RETENTION_ENABLE=1
MIRRORET_RETENTION_MODE=report
MIRRORET_RPM_KEEP_VERSIONS=3
MIRRORET_PIP_KEEP_VERSIONS=3
MIRRORET_NPM_KEEP_DAYS=180
MIRRORET_LOG_KEEP_DAYS=30
EOF
```

### VERIFY

```bash
grep -E '^MIRRORET_(APT|RPM)_TARGETS|^MIRRORET_RPM_REPOS|^MIRRORET_CA_BUNDLE' \
    /etc/mirroret/mirroret.conf
```

---

## Part 7. Apply

Preview first. Changes nothing:

```bash
sudo ./install.sh --upgrade --dry-run
```

Then apply:

```bash
sudo ./install.sh --upgrade
```

Watch for a line reading `Verdaccio binary:` followed by a real path.
If it says `/usr/bin/verdaccio`, that path does not exist and the service
will fail; report it.

### VERIFY the targets resolved

```bash
mirroretctl targets
```

Every target you configured must be listed, each with an upstream URL and a
repo/suite list. At this point each will say "not synced yet" - that is
expected before the first sync.

STOP if a target you configured is missing, or if install.sh printed
"no target resolved".

### VERIFY the generated scripts picked up the settings

```bash
ls -l /srv/mirroret/scripts/sync-apt-repos.sh /srv/mirroret/scripts/sync-rpm-repos.sh
grep -c -- '--spec'                   /srv/mirroret/scripts/sync-rpm-repos.sh
grep -c 'flock -n 9'                  /srv/mirroret/scripts/sync-rpm-repos.sh
grep -c '/etc/mirroret/mirroret.conf' /srv/mirroret/scripts/sync-rpm-repos.sh
grep -c 'timeout -k 60'               /srv/mirroret/scripts/sync-rpm-repos.sh
grep -c 'https_proxy'                 /srv/mirroret/scripts/sync-rpm-repos.sh
```

All counts must be 1 or more, for both scripts. The `https_proxy` line is
what makes the nightly cron run work: cron does not read
`/etc/environment` or shell rc files, so without it scheduled syncs fail
while manual runs succeed.

### VERIFY the source-RPM guard

```bash
grep -E '"(newest_only|sources)"' /etc/mirroret/targets/rpm-ol-9.json
```

Expected `"newest_only": true` and `"sources": false`. Source RPMs are
400-600 MB each and OL9 appstream carries roughly 44,000 of them.

STOP if `sources` is true unless you have deliberately sized the volume for
multiple terabytes.

---

## Part 8. Check the services

```bash
./mirroretctl status
```

Expected: nginx, pypiserver, verdaccio and the registry all `active`.

If verdaccio is not active:

```bash
sudo systemctl status verdaccio --no-pager | head -8
sudo journalctl -u verdaccio -n 60 --no-pager
```

`./mirroretctl status` prints the exact missing binary path when a unit
is stuck in a restart loop. Report that line.

### Endpoint check

```bash
./mirroretctl serve
```

Expected: PASS for nginx, pip, npm and docker, and `/logs/` plus
`/scripts/` reported as blocked. Those two must be blocked; sync logs can
contain the proxy URL.

---

## Part 9. First sync

Both engines estimate the download before starting and abort if it would
breach the disk floor, so a target that does not fit says so in seconds
rather than at 04:00 with a full volume.

Do RPM first: it is usually the bulk of the data.

```bash
sudo ./mirroretctl sync rpm
```

Read the first 20 lines. Expected, per repo:

```
--- repo baseos <- https://yum.oracle.com/repo/OracleLinux/OL9/baseos/latest/x86_64/
  upstream lists N packages; M selected (arches=noarch,x86_64 newest_only=True source=False)
  packages: M selected, M to download (N GB), 0 already on disk
```

`source=False` is the important one. If it says `source=True`, stop the sync
and fix `MIRRORET_RPM_SOURCE` - source RPMs are 400-600 MB each.

Then APT:

```bash
sudo ./mirroretctl sync apt
```

Expected, per suite:

```
--- suite jammy <- http://archive.ubuntu.com/ubuntu
  signature: NOT verified locally (no archive keyring found)
             The upstream signature is mirrored verbatim, so clients still
             verify it against their own archive keyring.
  indices: N files, M packages listed
  packages: M to download (N GB), 0 already on disk
  ...
  published: dists/jammy (N index files)
```

The `signature: NOT verified locally` line is expected on a RHEL host, which
has no `ubuntu-archive-keyring`. It is not a security gap: the archive is
mirrored byte-for-byte including its signature, and every client re-verifies
it with its own keyring.

`published:` appears only after every package that suite's indices list is on
disk. If a sync is interrupted you will not see it, and clients keep using
the previous state rather than hitting 404s.

Both take hours. Follow along in another session:

```bash
./mirroretctl logs tail
```

Then the rest:

```bash
sudo ./mirroretctl sync pip
sudo ./mirroretctl sync npm
```

The npm run should log `CACHED: <package> (+ deps: N)`. It no longer needs
credentials - it warms Verdaccio's cache by installing through it, which also
caches the whole dependency tree.

### VERIFY

```bash
mirroretctl targets          # every target should now report "published"
./mirroretctl logs errors
./mirroretctl sync last
sudo du -sh /srv/mirroret/redhat/mirror/*/*/* /srv/mirroret/apt/*
df -h /srv/mirroret
```

STOP if `mirroretctl targets` still says "not synced yet" for a target whose
sync reported success - that means the data landed somewhere the client URLs
do not point at.

---

## Part 10. Full check

```bash
./mirroretctl doctor
./mirroretctl client verify
./mirroretctl config diff
```

`client verify` must not report failures. It checks for `gpgcheck=1` with
no `gpgkey`, a wrong `signed-by`, invalid JSON, and baseurl paths that are
not on disk.

`config diff` shows where /etc/mirroret/mirroret.conf disagrees with the
generated scripts. If they disagree, re-run `sudo ./install.sh --upgrade`.

---

## Part 11. Optional: put the CLI on PATH

```bash
sudo ln -sf ~/mirroret-main/mirroretctl /usr/local/bin/mirroretctl
mirroretctl status
```

Do not delete or move `~/mirroret-main` after this. The generated
`cleanup-all.sh` loads library files from the install tree. It will fall
back to a search, but pinning the path is cleaner:

```bash
echo 'MIRRORET_INSTALL_DIR=/home/serob/mirroret-main' | sudo tee -a /etc/mirroret/mirroret.conf
sudo ./install.sh --upgrade
```

---

## Part 12. Remove the old tree

Only after everything above passes:

```bash
rm -rf ~/mirroret-main.prev ~/mirroret.zip
```

---

## Part 13. Point a client at the mirror

Only after the server sync has completed. `mirroretctl client list` on the
server prints the exact URL for every generated config.

### Oracle Linux / Rocky / Alma / RHEL clients

```bash
sudo curl -fsSL -o /etc/yum.repos.d/mirroret.repo \
    http://192.168.30.110:8080/config/ol9.repo
```

Disable the upstream repos, otherwise dnf keeps reaching the internet and
bypasses the mirror:

```bash
sudo dnf config-manager --set-disabled "*"
sudo dnf config-manager --set-enabled "mirroret-*"
sudo dnf clean all
sudo dnf repolist
```

Only `mirroret-*` entries should be enabled. Test:

```bash
sudo dnf check-update
sudo dnf install -y bash          # should download from 192.168.30.110
```

No GPG key to import: mirrored RPMs keep their upstream signature, and the
generated `.repo` points `gpgkey` at the vendor key already present in
`/etc/pki/rpm-gpg/`.

### Ubuntu / Debian clients

```bash
sudo curl -fsSL -o /etc/apt/sources.list.d/mirroret.list \
    http://192.168.30.110:8080/config/ubuntu-jammy.list
```

Disable the upstream entries, or apt keeps going to the internet:

```bash
sudo mv /etc/apt/sources.list /etc/apt/sources.list.disabled-by-mirroret
# On 24.04 and other deb822 hosts, also:
sudo rm -f /etc/apt/sources.list.d/ubuntu.sources

sudo apt-get update
apt-cache policy bash | head -5   # must show 192.168.30.110
sudo apt-get install -y --reinstall bash
```

Again no key to import: the mirrored `Release` files carry the upstream
Ubuntu/Debian signature, and the client verifies them with the
`ubuntu-archive-keyring` it already ships. A `.sources` (deb822) variant is
generated alongside the `.list` if you prefer that format.

### If a client reports 404 on Packages

Run on the SERVER:

```bash
mirroretctl client verify
```

It flags any suite or repo that a generated config advertises but which has
not been published yet, and tells you which sync to run.

---

## Daily operation

```bash
mirroretctl status          # health
mirroretctl logs errors     # what failed recently
mirroretctl sync status     # is a sync running
mirroretctl doctor          # full diagnostic
```

Cron already runs a daily sync and a weekly cleanup:

```bash
sudo crontab -l
```

```
# >>> mirroret managed (do not edit between markers) >>>
0 2 * * * /srv/mirroret/scripts/sync-all.sh
0 3 * * 0 /srv/mirroret/scripts/cleanup-all.sh
# <<< mirroret managed <<<
```

### Turning retention on for real

It ships in report mode. Review a dry run first:

```bash
sudo ./mirroretctl clean report
```

If the output looks right, switch to prune:

```bash
sudo sed -i 's/^MIRRORET_RETENTION_MODE=.*/MIRRORET_RETENTION_MODE=prune/' /etc/mirroret/mirroret.conf
sudo ./mirroretctl clean prune
```

---

## Rollback

```bash
sudo ./install.sh --list-backups
sudo ./install.sh --rollback BACKUP-ID
```

Full removal, keeping mirror data:

```bash
sudo ./uninstall.sh --list      # preview, changes nothing
sudo ./uninstall.sh --all
```

Full removal including all mirror data. Irreversible:

```bash
sudo ./uninstall.sh --all --purge
```

---

## What to report back

If a STOP checkpoint fails, send:

1. The command you ran and its full output
2. `sudo ./mirroretctl doctor`
3. `sudo journalctl -u SERVICE -n 100 --no-pager` for any failing service
4. `df -h /srv/mirroret`

## Notes on scope

One host serves every distro family you list in `MIRRORET_APT_TARGETS` and
`MIRRORET_RPM_TARGETS`, regardless of what that host runs. This runbook's
example configures Oracle Linux 9 plus Ubuntu 22.04/24.04 plus Debian 12
from a single RHEL 9 server. Adding another family is a config line and a
sync, not another host.

What still needs care:

* **Disk.** Each APT flavor is 300-600 GB for all four components.
  `MIRRORET_APT_COMPONENTS="main restricted"` cuts that by roughly 90%.
  Releases of the same flavor share one `pool/`, so a second Ubuntu release
  is cheap; a second *flavor* is not.
* **Mirroring RHEL itself** from `cdn.redhat.com` needs this host's
  entitlement certificate. The engine picks up `/etc/pki/entitlement/*.pem`
  automatically on a registered host, but the content set you can mirror is
  whatever this host's subscription grants.
* **repo_gpgcheck.** A filtered RPM mirror (an arch subset, or the default
  newest-only) has locally rebuilt `repomd.xml`, so clients cannot use
  `repo_gpgcheck=1` against it. Package signatures are untouched, so
  `gpgcheck=1` still verifies the vendor's signature.
