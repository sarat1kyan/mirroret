# Deploy runbook

For the admin deploying mirroret to the mirror server.

Target: RHEL 9 host serving Oracle Linux 9 clients, behind an HTTP proxy
that restricts which upstream hosts it will connect to.

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
sudo pkill -f sync-redhat-repos
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

`files.pythonhosted.org` is required in addition to `pypi.org`. Wheels are
served from it; allowing only pypi.org fails every download.

### What you can do before the allow-list lands

If `yum.oracle.com` is reachable, the RPM mirror is the bulk of the data
and can sync now. Continue through the runbook, and at Part 9 run only:

```bash
sudo ./mirroretctl sync rpm
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

## Part 5. Fix the Oracle repo definitions

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
```

Import the Oracle signing key:

```bash
sudo curl -fsSL -o /etc/pki/rpm-gpg/RPM-GPG-KEY-oracle https://yum.oracle.com/RPM-GPG-KEY-oracle-ol9
```

Refresh:

```bash
sudo dnf clean all
sudo dnf makecache
```

### VERIFY

```bash
grep baseurl /etc/yum.repos.d/oracle-linux-ol9.repo
sudo dnf repolist | grep ol9_
```

No `$` may appear in any baseurl. All four ol9 repos must be listed.

STOP if this fails.

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

# Serve Oracle Linux 9 from this RHEL host.
MIRRORET_RPM_FLAVOR=ol
MIRRORET_RPM_REPOS="ol9_baseos_latest ol9_appstream ol9_UEKR8 ol9_developer_EPEL"

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

# npm: let the sync publish without a login.
MIRRORET_NPM_ALLOW_ANON_PUBLISH=1

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
grep -E '^MIRRORET_RPM_FLAVOR|^MIRRORET_RPM_REPOS|^MIRRORET_CA_BUNDLE' /etc/mirroret/mirroret.conf
```

---

## Part 7. Apply

Force the RPM sync script to regenerate, so the new settings take effect:

```bash
sudo rm -f /srv/mirroret/scripts/sync-redhat-repos.sh
```

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

### VERIFY the generated script picked up the settings

```bash
grep -E '^FLAVOR=|^ARCH=|^NEWEST_ONLY=|^INCLUDE_SOURCE=|^REPOS=' /srv/mirroret/scripts/sync-redhat-repos.sh
```

Expected:

```
FLAVOR="ol"
ARCH="x86_64"
NEWEST_ONLY="1"
INCLUDE_SOURCE="0"
REPOS=(ol9_baseos_latest ol9_appstream ol9_UEKR8 ol9_developer_EPEL)
```

And confirm the guards are in place:

```bash
grep -c 'flock -n 9'                  /srv/mirroret/scripts/sync-redhat-repos.sh
grep -c '_check_disk'                 /srv/mirroret/scripts/sync-redhat-repos.sh
grep -c '/etc/mirroret/mirroret.conf' /srv/mirroret/scripts/sync-redhat-repos.sh
grep -c 'timeout -k 60'               /srv/mirroret/scripts/sync-redhat-repos.sh
```

All must be 1 or more.

STOP if FLAVOR is not `ol` or INCLUDE_SOURCE is not `0`.

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

The RPM sync now estimates the download before starting and aborts if it
would breach the disk floor.

```bash
sudo ./mirroretctl sync rpm
```

Read the first 30 lines. Expected:

```
arch=x86_64  newest_only=1  source=0  delete=1
--- Estimating download size (metadata only)
    ol9_baseos_latest: ~N GB
    ...
    total: ~N GB   free: N GB
```

The word `getPackageSource` must not appear. If it does, stop the sync
and report it: source RPMs are being pulled.

This takes hours. Follow along in another session:

```bash
./mirroretctl logs tail
```

Then the rest:

```bash
sudo ./mirroretctl sync pip
sudo ./mirroretctl sync npm
```

### VERIFY

```bash
./mirroretctl logs errors
./mirroretctl sync last
sudo du -sh /srv/mirroret/redhat/mirror/ol/9/*
df -h /srv/mirroret
```

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

Run on each Oracle Linux client, only after the server sync has completed.

```bash
sudo curl -fsSL -o /etc/yum.repos.d/mirroret.repo http://192.168.30.110:8080/config/redhat-client.repo
```

Disable the upstream repos, otherwise dnf keeps reaching the internet and
bypasses the mirror:

```bash
sudo dnf config-manager --disable ol9_baseos_latest ol9_appstream ol9_UEKR8 ol9_developer_EPEL
sudo dnf clean all
sudo dnf repolist
```

Only `mirroret-*` entries should be enabled.

Test:

```bash
sudo dnf update
```

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

## Known limitation

The mirror server is RHEL and serves Oracle Linux 9 clients. Mirroret can
mirror one distro family per host. To also serve RHEL or Debian clients
you need a separate mirror host for each.
