# Proxy and Corporate TLS Inspection

This guide covers running mirroret behind an HTTP/HTTPS proxy and behind
a TLS-inspecting middlebox that re-signs traffic with a private CA.

Everything here is **generic**: no host, IP, or vendor name is baked in.
Where a path differs by distribution, both are listed.

---

## 1. Decide what kind of network you're on

| Symptom | Likely cause |
|---|---|
| Direct outbound TCP works, but only to a small set of hosts | Egress firewall - set allow-list per `docs/NETWORK_ACCESS.md` |
| Some tools work (curl), others fail with cert errors | Corporate TLS inspection with a private CA |
| No tool works outbound; "connection refused" or timeouts | HTTP/HTTPS proxy required |
| `pip` works in a user shell but not under sudo | sudo strips `*_proxy` from env |
| Cron-driven sync fails the same way every night | systemd / cron does not inherit your shell env |

You can almost always tell from `scripts/mirroret-debug.sh --net` output.

---

## 2. HTTP/HTTPS proxy: per-tool configuration

Set both `http_proxy` and `https_proxy`. Include `no_proxy` for local
addresses so the mirror server itself can still reach localhost and the
internal subnet.

```bash
export http_proxy="http://proxy.example.internal:3128"
export https_proxy="http://proxy.example.internal:3128"
export no_proxy="localhost,127.0.0.1,::1,.internal,10.0.0.0/8,192.168.0.0/16"
```

### sudo (preserve env across the privilege boundary)

By default `sudo` strips the proxy variables. Pick one:

```bash
# Option A - pass through every time you run sudo:
sudo -E ./install.sh

# Option B - make proxy variables permanently sudo-safe:
sudo install -m 0644 /dev/stdin /etc/sudoers.d/keep-proxy <<'EOF'
Defaults env_keep += "http_proxy https_proxy no_proxy HTTP_PROXY HTTPS_PROXY NO_PROXY"
EOF
sudo visudo -c # verify
```

### apt-get / apt (Debian/Ubuntu)

```bash
sudo install -m 0644 /dev/stdin /etc/apt/apt.conf.d/80proxy <<EOF
Acquire::http::Proxy "${http_proxy}";
Acquire::https::Proxy "${https_proxy}";
EOF
```

### dnf / yum (RHEL family)

```bash
# In /etc/dnf/dnf.conf or /etc/yum.conf, add:
sudo sed -i.bak '/^\[main\]/a proxy='"${http_proxy}" /etc/dnf/dnf.conf
```

### pip

```bash
# Per-shell:
pip install --proxy "${https_proxy}" requests

# Persistent (system-wide):
sudo install -m 0644 /dev/stdin /etc/pip.conf <<EOF
[global]
proxy = ${https_proxy}
EOF
```

### npm

```bash
npm config set proxy "${http_proxy}"
npm config set https-proxy "${https_proxy}"
npm config set noproxy "${no_proxy}"
```

### Docker (rootful)

The Docker daemon reads its own environment, not the shell's.

```bash
# Drop-in for the docker.service unit:
sudo mkdir -p /etc/systemd/system/docker.service.d
sudo install -m 0644 /dev/stdin /etc/systemd/system/docker.service.d/proxy.conf <<EOF
[Service]
Environment="HTTP_PROXY=${http_proxy}"
Environment="HTTPS_PROXY=${https_proxy}"
Environment="NO_PROXY=${no_proxy}"
EOF
sudo systemctl daemon-reload
sudo systemctl restart docker
```

### Podman (rootful)

Same shape, against `podman` or `podman.service`. For one-shot pulls
under `sudo`, `sudo -E podman pull ...` is enough.

### Podman (rootless)

Drop the env file under the **invoking user's** systemd-user dir:

```bash
mkdir -p ~/.config/containers/systemd/
mkdir -p ~/.config/environment.d/
cat > ~/.config/environment.d/90-proxy.conf <<EOF
HTTP_PROXY=${http_proxy}
HTTPS_PROXY=${https_proxy}
NO_PROXY=${no_proxy}
EOF
systemctl --user import-environment HTTP_PROXY HTTPS_PROXY NO_PROXY
```

### systemd services that mirroret creates

`pypiserver` and `verdaccio` units run under dedicated system users.
If they need outbound, add a drop-in:

```bash
sudo mkdir -p /etc/systemd/system/verdaccio.service.d
sudo install -m 0644 /dev/stdin /etc/systemd/system/verdaccio.service.d/proxy.conf <<EOF
[Service]
Environment="HTTP_PROXY=${http_proxy}"
Environment="HTTPS_PROXY=${https_proxy}"
Environment="NO_PROXY=${no_proxy}"
EOF
sudo systemctl daemon-reload
sudo systemctl restart verdaccio
```

### Cron-driven sync scripts

cron does **not** inherit your interactive shell. Either:

```bash
# Option A - put the env in root's crontab above the managed block:
sudo crontab -e
# Add the four lines at the top:
http_proxy=http://proxy.example.internal:3128
https_proxy=http://proxy.example.internal:3128
no_proxy=localhost,127.0.0.1,.internal
HTTPS_PROXY=$https_proxy

# Option B - put them in /etc/environment so all cron jobs see them:
sudo install -m 0644 /dev/stdin /etc/environment.proxy <<EOF
http_proxy="http://proxy.example.internal:3128"
https_proxy="http://proxy.example.internal:3128"
no_proxy="localhost,127.0.0.1,.internal"
EOF
# then prepend `. /etc/environment.proxy; ` to the cron command, OR
# wrap the script in one that sources the file first.
```

Re-run `scripts/mirroret-debug.sh --net` from a non-interactive shell
(`env -i bash -c 'scripts/mirroret-debug.sh --net'`) to confirm.

---

## 2b. First: confirm whether you actually HAVE TLS inspection

Do not install a CA before checking. A proxy that refuses CONNECT and a
proxy that re-signs TLS produce similar-looking errors, but the fixes are
completely different.

Ask the proxy what certificate chain it presents:

```bash
openssl s_client -connect yum.oracle.com:443 -proxy PROXY_HOST:PORT -showcerts </dev/null 2>/dev/null \
  | grep -E '^ *[0-9]+ s:|^ *i:'
```

**No inspection** (issuer is a real public CA, nothing to install):

```
0 s: O=Oracle Corporation, CN=yum.oracle.com
  i: O=DigiCert Inc, CN=DigiCert Global G3 TLS ECC SHA384 2020 CA1
1 s: O=DigiCert Inc, CN=DigiCert Global G3 TLS ECC SHA384 2020 CA1
  i: O=DigiCert Inc, CN=DigiCert Global Root G3
```

**Inspection present** (issuer is a corporate name, section 3 applies):

```
0 s: CN=yum.oracle.com
  i: CN=Acme Issuing CA
1 s: CN=Acme Issuing CA
  i: CN=Acme Root CA
```

### Telling the two failures apart

| Observed | Cause | Fix |
|---|---|---|
| `403 from proxy after CONNECT`, code 000 | proxy policy blocks the host | allow-list, section 2c |
| `packet length too long` | proxy returned a plaintext HTML block page where TLS was expected. Same as above. | allow-list, section 2c |
| `certificate verify failed`, `unable to get local issuer certificate` | genuine TLS inspection | install the CA, section 3 |
| Corporate name in the issuer chain above | genuine TLS inspection | install the CA, section 3 |

`packet length too long` is the confusing one. It reads like a TLS problem
but it usually means the proxy blocked the request and the client parsed
the error page as a TLS record.

---

## 2c. Proxy allow-list

When the proxy blocks by policy there is nothing to configure on the
mirror server. Find out which hosts are blocked:

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

Any host returning 000 is blocked. Anything returning an HTTP code,
including 401 and 403 from the site itself, is reachable.

Then ask the proxy team to permit CONNECT on 443 to the blocked ones.

Do not overlook `files.pythonhosted.org`. Allowing only `pypi.org` passes
metadata but fails every actual download.

Never resolve a policy block by copying a private key off the proxy, and
never disable certificate verification (`npm config set strict-ssl false`,
`pip --trusted-host`) to work around it. Neither fixes a 403 and both
weaken every other fetch.

---

## 3. Corporate TLS inspection: trusting a private CA

When a middlebox re-signs HTTPS traffic, every tool independently rejects
it unless you teach the tool to trust the private CA root certificate.

Save the corporate root CA (ask your IT) as a `.crt` (PEM) file.

### Step 1 - install into the OS trust store

**Debian/Ubuntu:**
```bash
sudo cp corp-root-ca.crt /usr/local/share/ca-certificates/corp-root-ca.crt
sudo update-ca-certificates
```

**RHEL family:**
```bash
sudo cp corp-root-ca.crt /etc/pki/ca-trust/source/anchors/corp-root-ca.crt
sudo update-ca-trust extract
```

System-level tools (curl, wget, dnf, apt) will pick it up.

### Step 2 - teach pip

pip ships its own bundle. Point it at the system store:

```bash
sudo install -m 0644 /dev/stdin /etc/pip.conf <<'EOF'
[global]
cert = /etc/ssl/certs/ca-certificates.crt # Debian/Ubuntu
# cert = /etc/pki/tls/cert.pem # RHEL family
EOF
```

Or use the `REQUESTS_CA_BUNDLE` env var for the current shell:

```bash
export REQUESTS_CA_BUNDLE=/etc/ssl/certs/ca-certificates.crt
```

### Step 3 - teach npm

```bash
npm config set cafile /etc/ssl/certs/ca-certificates.crt # or RHEL path
# OR (less safe - disables verification entirely; do not use in production):
# npm config set strict-ssl false
```

### Step 4 - teach Docker (per upstream registry)

Docker / Podman read trust from a per-registry path, not the OS store.

**Rootful (Docker or rootful Podman):**
```bash
sudo mkdir -p /etc/docker/certs.d/registry-1.docker.io
sudo cp corp-root-ca.crt /etc/docker/certs.d/registry-1.docker.io/ca.crt
sudo systemctl restart docker # if applicable
```

**Rootless Podman:**
```bash
mkdir -p ~/.config/containers/certs.d/registry-1.docker.io
cp corp-root-ca.crt ~/.config/containers/certs.d/registry-1.docker.io/ca.crt
```

Repeat the directory for every upstream registry you actually pull from
(e.g. `quay.io`, `ghcr.io`, `gcr.io`).

### Step 5 - teach Go-based tools (registry, debmirror)

These honour the OS store after step 1. No extra config is normally needed.

### Step 6 - verify

```bash
curl -fsS https://pypi.org/ >/dev/null && echo OK pypi
curl -fsS https://registry.npmjs.org/ >/dev/null && echo OK npm
curl -fsS https://registry-1.docker.io/v2/ -o /dev/null && echo OK docker
```

If any step fails, the corporate CA is not yet trusted by that tool.

---

## 4. Quick reference

| Tool | Env var | Config file | CA dir |
|---|---|---|---|
| curl / wget | `*_proxy` | - | OS trust store |
| apt | - | `/etc/apt/apt.conf.d/80proxy` | OS trust store |
| dnf | - | `/etc/dnf/dnf.conf` | OS trust store |
| pip | `*_proxy`, `REQUESTS_CA_BUNDLE` | `/etc/pip.conf` | `cert =` in pip.conf |
| npm | - | `~/.npmrc` (`proxy`, `cafile`) | `cafile` |
| Docker (rootful) | - (read by daemon, not shell) | systemd drop-in | `/etc/docker/certs.d/<host>/ca.crt` |
| Podman rootful | - | systemd drop-in | `/etc/containers/certs.d/<host>/ca.crt` |
| Podman rootless | systemd-user `environment.d` | - | `~/.config/containers/certs.d/<host>/ca.crt` |
| systemd unit | `Environment=` drop-in | unit `.d/` | OS trust store |
| cron | `/etc/environment.proxy` or in crontab | crontab line | OS trust store |

`scripts/mirroret-debug.sh` reports whether each of these is configured
on the mirror host. Run it once before sync and once again after the
first sync attempt.

---

## 5. What mirroret itself does and doesn't do

- The installer does **not** rewrite the OS trust store. It expects step 1 to be done by the operator.
- The installer **does** detect a few common signals (proxy env vars set, custom CA anchors present) in preflight and prints actionable warnings - see `lib/preflight.sh`.
- The cron-driven sync scripts use `exec > >(tee ...)` so their exit codes are honest. A failing sync exits non-zero, so cron-mail will surface it on misconfigured proxy/CA.
- TLS inspection that re-signs `archive.ubuntu.com` / `deb.debian.org` will also re-sign the **package metadata signatures themselves**. apt clients will reject the mirrored Release files because they're signed by Canonical/Debian, not by the corporate CA. There is no fix for this short of either bypassing the middlebox for these hosts (allow-list) or running mirroret's own re-signing flow (`MIRRORET_APT_RESIGN=1`, plus a manual `apt-ftparchive` re-signing step - not yet automated).
