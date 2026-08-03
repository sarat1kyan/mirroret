# Environment fixes - things mirroret cannot fix for you

These are problems in **your infrastructure**, not bugs in the tool. Work
through them in order. Each has a verification step.

Host referenced throughout: the mirror server (`3311-LinuxRepo`,
`192.168.30.110`), RHEL 9.8, behind an HTTP proxy at `192.168.30.243:3128`
that performs TLS inspection.

---

## BLOCKER 1 - Proxy refuses CONNECT to some upstreams (403)

### Symptom

```
curl: (56) Received HTTP code 403 from proxy after CONNECT
pypi=000
curl: (56) Received HTTP code 403 from proxy after CONNECT
npm=000
docker=401
```

Earlier the same problem surfaced as:

```
Curl error (35): SSL connect error ... [error:0A0000C6:SSL routines::packet length too long]
```

Those are the same fault. When the proxy answers a CONNECT with a
plaintext HTTP 403 block page, a TLS client reports "packet length too
long" because it is trying to parse HTML as a TLS record.

### This is NOT TLS inspection

Confirmed by asking the proxy what chain it presents:

```bash
openssl s_client -connect yum.oracle.com:443 -proxy PROXY_HOST:PORT -showcerts </dev/null 2>/dev/null \
  | grep -E '^ *[0-9]+ s:|^ *i:'
```

On this environment that returns:

```
0 s: O=Oracle Corporation, CN=yum.oracle.com
  i: O=DigiCert Inc, CN=DigiCert Global G3 TLS ECC SHA384 2020 CA1
1 s: O=DigiCert Inc, CN=DigiCert Global G3 TLS ECC SHA384 2020 CA1
  i: O=DigiCert Inc, CN=DigiCert Global Root G3
```

That is the real Oracle certificate signed by a public CA. Nothing is
being re-signed, so there is no corporate CA to install. Do not install a
CA file to fix this, and do not copy a private key off the proxy.

If instead you see a corporate name in the issuer chain, you DO have TLS
inspection; follow docs/PROXY_AND_CA.md section 3 in that case.

### Determine exactly which hosts are blocked

```bash
for h in \
  yum.oracle.com \
  cdn.redhat.com \
  pypi.org \
  files.pythonhosted.org \
  registry.npmjs.org \
  registry-1.docker.io \
  auth.docker.io ; do
    printf '%-32s %s\n' "$h" \
      "$(curl -sS -o /dev/null -w '%{http_code}' --max-time 10 "https://$h/" 2>/dev/null)"
done
```

Reading the results:

| Code | Meaning |
|---|---|
| 200, 301, 302, 401, 403 from the SITE | reachable, fine |
| 000 plus "403 from proxy after CONNECT" | blocked by proxy policy |

Note 401 from registry-1.docker.io is correct and means reachable.

### Fix: proxy allow-list

There is nothing to change on the mirror server. Ask the proxy team to
permit CONNECT on port 443 to whichever of these came back blocked:

```
pypi.org
files.pythonhosted.org
registry.npmjs.org
auth.docker.io
production.cloudflare.docker.com
cdn.redhat.com
```

files.pythonhosted.org matters as much as pypi.org. That is where wheel
files are served from; allowing only pypi.org lets metadata through and
still fails every download.

### You can start before this is fixed

If yum.oracle.com is already reachable, the RPM mirror (the bulk of the
data) can sync now:

```bash
sudo ./mirroretctl sync rpm
```

pip and npm stay broken until the allow-list lands. Either skip them:

```bash
sudo ./install.sh --upgrade --no-pip --no-npm
```

or leave them configured and accept that those two steps fail nightly
until the proxy is opened.

---

## BLOCKER 2 - Oracle repo file contains unexpanded variables

### Symptom

```
SSL connect error for https://yum$ociregion.$ocidomain/repo/...
```

### Cause

`public-yum-ol9.repo` from Oracle uses `$ociregion` / `$ocidomain` dnf
variables. Those are defined by the `oraclelinux-release-el9` package,
which is **not installed on a RHEL host**. dnf leaves them literal.

Note: `sed 's|yum$ociregion...|'` does **not** work - `$` is a regex
anchor. It has to be escaped or the file rewritten.

### Fix

Replace the repo file with hardcoded hostnames:

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

[ol9_UEKR8]
name=Oracle Linux 9 UEK Release 8 (x86_64)
baseurl=https://yum.oracle.com/repo/OracleLinux/OL9/UEKR8/x86_64/
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-oracle
gpgcheck=1
enabled=1

[ol9_developer_EPEL]
name=Oracle Linux 9 EPEL Packages for Development (x86_64)
baseurl=https://yum.oracle.com/repo/OracleLinux/OL9/developer/EPEL/x86_64/
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-oracle
gpgcheck=1
enabled=1
EOF

sudo curl -fsSL -o /etc/pki/rpm-gpg/RPM-GPG-KEY-oracle \
    https://yum.oracle.com/RPM-GPG-KEY-oracle-ol9

sudo dnf clean all
sudo dnf makecache
```

Verify - no `$` should appear:

```bash
grep baseurl /etc/yum.repos.d/oracle-linux-ol9.repo
```

---

## HIGH 3 - Clock skew

### Symptom

```
The system clock is skewed. There is a time difference of 48.0 seconds
with the entitlement server.
```

### Why it matters

48 s of drift is survivable for dnf but breaks TLS certificate validity
windows and Kerberos, and it makes correlating logs across hosts painful.
It also invalidates `subscription-manager` entitlement checks.

### Fix

```bash
sudo timedatectl set-ntp true
sudo systemctl enable --now chronyd
sudo chronyc makestep
sleep 30
timedatectl | grep -E 'synchronized|Local time'
```

Must show `System clock synchronized: yes`. If it stays `no`:

```bash
sudo chronyc sources -v
```

Look for a source prefixed `^*`. If none, the proxy is blocking NTP
(UDP 123). Ask IT for an internal NTP server and add it:

```bash
echo "server <internal-ntp-host> iburst" | sudo tee -a /etc/chrony.conf
sudo systemctl restart chronyd
```

---

## HIGH 4 - Mirror server is RHEL but you want to serve Oracle Linux

### Situation

The mirror host runs RHEL 9.8. Its own subscription grants
`rhel-9-for-x86_64-*` repos. Your clients are Oracle Linux 9.

Mirroret defaults to mirroring whatever the **host** distro is. To mirror
OL9 from a RHEL host you must tell it explicitly.

### Fix

```bash
sudo mkdir -p /etc/mirroret
sudo cp ~/mirroret-main/config/mirroret.conf.example /etc/mirroret/mirroret.conf

sudo tee -a /etc/mirroret/mirroret.conf >/dev/null <<'EOF'

# Serve Oracle Linux 9 to clients from this RHEL host.
MIRRORET_RPM_FLAVOR=ol
MIRRORET_RPM_REPOS="ol9_baseos_latest ol9_appstream ol9_UEKR8 ol9_developer_EPEL"

# Sync safety (see BLOCKER 5 below).
MIRRORET_RPM_ARCH=x86_64
MIRRORET_RPM_NEWEST_ONLY=1
MIRRORET_RPM_SOURCE=0
MIRRORET_RPM_DELETE=1
MIRRORET_SYNC_MIN_FREE_GB=15

# Quiet the npm publish failures.
MIRRORET_NPM_ALLOW_ANON_PUBLISH=1

# Retention - start in report mode, review, then switch to prune.
MIRRORET_RETENTION_ENABLE=1
MIRRORET_RETENTION_MODE=report
MIRRORET_RPM_KEEP_VERSIONS=3
MIRRORET_PIP_KEEP_VERSIONS=3
MIRRORET_NPM_KEEP_DAYS=180
EOF
```

Then force the sync script to regenerate and verify:

```bash
sudo rm -f /srv/mirroret/scripts/sync-redhat-repos.sh
cd ~/mirroret-main
sudo ./install.sh --upgrade
grep -E '^FLAVOR=|^REPOS=|^ARCH=|^INCLUDE_SOURCE=' /srv/mirroret/scripts/sync-redhat-repos.sh
```

Expected:

```
FLAVOR="ol"
ARCH="x86_64"
INCLUDE_SOURCE="0"
REPOS=(ol9_baseos_latest ol9_appstream ol9_UEKR8 ol9_developer_EPEL)
```

### Note

The RHEL host's own `rhel-9-*` tree already synced (15,416 + 35,594
packages under `/srv/mirroret/redhat/mirror/rhel/9/`). That is ~130 GB of
your 117 GB remaining. Decide whether you still want it:

```bash
sudo du -sh /srv/mirroret/redhat/mirror/rhel/9/*
# To drop it and reclaim space:
sudo rm -rf /srv/mirroret/redhat/mirror/rhel
```

---

## BLOCKER 5 - Source-RPM runaway (FIXED in the tool, but clean up)

### What happened

A sync pulled `getPackageSource/*.src.rpm` - 44,335 packages at
400-600 MB each. That is multiple terabytes. It was still running when
you caught it.

### Tool-side status

**Fixed.** `reposync` now runs with `--arch x86_64 --arch noarch
--newest-only --delete`, and source RPMs are off by default
(`MIRRORET_RPM_SOURCE=0`). A disk-floor guard aborts the sync when free
space drops below `MIRRORET_SYNC_MIN_FREE_GB`.

### Your cleanup

Kill any still-running sync and remove the partial source downloads:

```bash
sudo pkill -f reposync
sudo pkill -f sync-redhat-repos

# Find and remove any .src.rpm that got written:
sudo find /srv/mirroret/redhat -name '*.src.rpm' -type f | wc -l
sudo find /srv/mirroret/redhat -name '*.src.rpm' -type f -delete

# Reclaim dnf cache too:
sudo dnf clean all
sudo rm -rf /var/cache/dnf/*

df -h /srv/mirroret
```

---

## MED 6 - Verdaccio stuck in `activating`

### Symptom

`mirroret-debug.sh` reports `verdaccio: activating` (restart loop), port
4873 shows `free`.

### Diagnose

```bash
sudo journalctl -u verdaccio -n 100 --no-pager
sudo systemctl status verdaccio --no-pager
```

### Common causes

| Log line | Fix |
|---|---|
| `EACCES ... /srv/mirroret/npm/approved` | `sudo chown -R mirroret-npm: /srv/mirroret/npm` |
| `Cannot find module` | Reinstall: `sudo npm install -g verdaccio` |
| `config.yaml ... YAMLException` | `sudo rm /etc/verdaccio/config.yaml && sudo ./install.sh --upgrade` |
| `listen EADDRINUSE` | Something else on 4873: `sudo ss -lntp \| grep 4873` |

Send me the journalctl output if none of these match.

---

## MED 7 - npm publish `ENEEDAUTH`

### Symptom

```
npm error code ENEEDAUTH
npm error need auth This command requires you to be logged in to http://localhost:4873/
  PUBLISH FAILED (auth required?): express
```

7 failures per sync run.

### Cause

Verdaccio's default config requires authentication for publish. The cron
sync runs unauthenticated.

### Impact

Cosmetic for pull-through caching - clients installing via the mirror
still work through Verdaccio's npmjs uplink. Only pre-seeding fails.

### Fix

```bash
sudo sed -i 's|publish: \$authenticated|publish: $all|g; s|unpublish: \$authenticated|unpublish: $all|g' \
    /etc/verdaccio/config.yaml
sudo systemctl restart verdaccio
```

Plus `MIRRORET_NPM_ALLOW_ANON_PUBLISH=1` in `mirroret.conf` (already in
the block from item 4) so `--upgrade` keeps it that way.

---

## MED 8 - Clients still reaching upstream directly

### Symptom (on the OL client)

```
Curl error (28): Timeout was reached for
https://yum.oracle.com/repo/.../repodata/repomd.xml
```

The client's own `ol9_developer_EPEL` repo is enabled and pointing at
the internet, so `dnf` tries upstream instead of your mirror.

### Fix on each Oracle Linux client

Only do this **after** the server-side OL9 mirror has actually synced.

```bash
# Point at the mirror:
sudo curl -fsSL -o /etc/yum.repos.d/mirroret.repo \
    http://192.168.30.110:8080/config/redhat-client.repo

# Disable the upstream repos so dnf uses only the mirror:
sudo dnf config-manager --disable \
    ol9_baseos_latest ol9_appstream ol9_UEKR8 ol9_developer_EPEL

sudo dnf clean all
sudo dnf repolist
```

`repolist` should show only `mirroret-*` entries enabled.

---

## LOW 9 - RHEL subscription not receiving updates

### Symptom

```
This system is registered with an entitlement server, but is not
receiving updates. You can use subscription-manager to assign
subscriptions.
```

### Assessment

Non-blocking. The repos are reachable (`dnf repolist` works). This is
Simple Content Access reporting style plus the clock skew from item 3.
Fix the clock first and re-check:

```bash
sudo subscription-manager status
sudo subscription-manager refresh
```

---

## Ordered runbook

```bash
# 1. Stop the runaway
sudo pkill -f reposync; sudo pkill -f sync-redhat-repos
sudo find /srv/mirroret/redhat -name '*.src.rpm' -delete
sudo dnf clean all

# 2. Clock
sudo timedatectl set-ntp true
sudo systemctl enable --now chronyd
sudo chronyc makestep

# 3. Corporate CA <-- get the cert from IT first
sudo cp corp-root-ca.crt /etc/pki/ca-trust/source/anchors/
sudo update-ca-trust extract

# 4. Oracle repo file (see BLOCKER 2 for the full heredoc)

# 5. Mirroret config (see HIGH 4 for the full heredoc)

# 6. Regenerate + upgrade
cd ~/mirroret-main
git fetch origin && git reset --hard origin/main
sudo rm -f /srv/mirroret/scripts/sync-redhat-repos.sh
sudo ./install.sh --upgrade

# 7. Verify the guards are in the generated script
grep -E '^ARCH=|^INCLUDE_SOURCE=|^NEWEST_ONLY=|_check_disk|flock' \
    /srv/mirroret/scripts/sync-redhat-repos.sh

# 8. Verdaccio
sudo journalctl -u verdaccio -n 100 --no-pager

# 9. First guarded sync
sudo /srv/mirroret/scripts/sync-redhat-repos.sh

# 10. Verify
sudo ./scripts/mirroret-debug.sh
sudo du -sh /srv/mirroret/redhat/mirror/ol/9/*
df -h /srv/mirroret
```

Items 3 and 4 are the two that actually gate everything else. Without the
CA (or a proxy allow-list) no upstream sync can succeed at all.

---

## Appendix - Transferring mirroret when the server has no GitHub access

The mirror server cannot reach github.com. Move the code in as a zip from
a machine that can.

### Step 1 - on a machine WITH internet (your laptop/workstation)

```bash
curl -L -o mirroret.zip \
    https://github.com/sarat1kyan/mirroret/archive/refs/heads/main.zip
```

Or in a browser: `https://github.com/sarat1kyan/mirroret` -> Code ->
Download ZIP.

### Step 2 - copy it to the mirror server

Pick whichever you have:

```bash
# scp
scp mirroret.zip serob@192.168.30.110:~/

# MobaXterm: drag mirroret.zip into the left-hand SFTP pane

# USB / shared drive: copy the file, then move it to ~ on the server
```

### Step 3 - on the mirror server

```bash
cd ~
# Keep the old tree until the new one is verified.
[[ -d mirroret-main ]] && mv mirroret-main mirroret-main.prev

unzip -o mirroret.zip
cd mirroret-main

# A zip does NOT preserve the execute bit. Restore it or nothing runs.
chmod +x install.sh uninstall.sh scripts/*.sh

# Confirm you got the version you expect:
grep -c 'mirroret_script_preamble' lib/common.sh # expect >= 1
grep -c 'logs|scripts|staging' lib/nginx.sh # expect >= 1
```

### Step 4 - apply

```bash
sudo ./install.sh --upgrade
sudo ./scripts/mirroret-debug.sh
```

### Step 5 - once verified, drop the old tree

```bash
rm -rf ~/mirroret-main.prev ~/mirroret.zip
```

### Important - do not delete the old tree before running `--upgrade`

`cleanup-all.sh` embeds the install-tree path as `INSTALL_DIR`. If you
delete or rename the directory it was generated from without re-running
`--upgrade`, the weekly cron cleanup exits 2 silently forever. Running
`--upgrade` from the new path regenerates it with the correct path.

### Verifying the transfer was complete

```bash
# Should be ~20 lib modules and 6+ test files:
ls lib/*.sh | wc -l
ls tests/*.bats | wc -l

# Should print the current flag set:
bash install.sh --help | grep -E 'upgrade|cleanup'
```

If `lib/` is short or `--help` errors, the zip extracted partially -
re-download and repeat.
