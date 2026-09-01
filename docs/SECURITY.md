# Security

## What protects a client

Mirrored content keeps its **upstream** signatures:

- APT: `InRelease` / `Release` / `Release.gpg` are copied byte for byte. The
  client verifies them with the `ubuntu-archive-keyring` /
  `debian-archive-keyring` it already ships. Generated client configs point
  `signed-by=` at that stock keyring. mirroret never re-signs.
- RPM: packages keep their vendor signature. Generated `.repo` files set
  `gpgcheck=1` with `gpgkey=` pointing at the vendor key already in
  `/etc/pki/rpm-gpg/` on a stock client.

So **no key needs to be generated or distributed for mirrored suites and
repos**. The same holds in hybrid and cache storage modes: the daemon passes
indices through unchanged, and apt checks the SHA256 chain from `Release`
to `Packages` to each `.deb` itself ([CACHE.md](CACHE.md)).

The mirror server may verify the upstream signature too
(`MIRRORET_APT_REQUIRE_SIGNATURE=1`); that needs the archive keyring
installed on the server and is defence in depth, not the boundary.

One thing a filtered RPM mirror cannot offer: `repo_gpgcheck=1` (repodata is
rebuilt locally, so upstream's `repomd.xml.asc` no longer applies). Package
signatures are unaffected. Mirror everything
(`MIRRORET_RPM_NEWEST_ONLY=0`, no arch filter, or
`MIRRORET_RPM_KEEP_UPSTREAM_METADATA=1`) to keep upstream's signed metadata.

---

## Insecure modes (lab only, explicit opt-in)

```bash
sudo ./install.sh --insecure               # all four at once
sudo MIRRORET_APT_INSECURE=1 ./install.sh  # or one at a time
```

| Variable | Effect on generated client config |
|---|---|
| `MIRRORET_APT_INSECURE=1` | `trusted=yes` - apt skips signature checks |
| `MIRRORET_RPM_INSECURE=1` | `gpgcheck=0` |
| `MIRRORET_DOCKER_INSECURE=1` | `insecure-registries` |
| `MIRRORET_PIP_INSECURE=1` | flagged insecure (a plain-HTTP index needs `trusted-host` anyway) |

A warning is printed at install time and written into the generated files.

---

## Custom repositories and re-signing (`--gpg-auto`, `MIRRORET_APT_RESIGN`)

Only needed if you publish your **own** packages or re-sign the mirrored
metadata. For plain mirroring, skip this section.

### Generating a mirroret key

```bash
sudo ./install.sh --gpg-auto
# or MIRRORET_GPG_AUTO=1 in the conf, or MIRRORET_GPG_KEYID=<fingerprint>
```

- Creates a 4096-bit RSA key without passphrase in `MIRRORET_GPG_HOMEDIR`
  (`/etc/mirroret/gnupg`), or uses `MIRRORET_GPG_KEYID`.
- Exports `/srv/mirroret/config/GPG-KEY.asc` (armored) and
  `/srv/mirroret/config/mirroret.gpg` (binary), served under `/config/`.
- Writes `/srv/mirroret/config/import-mirroret-gpg-key.sh`, which a client
  can run to install the key into `/etc/apt/keyrings/mirroret.gpg`.
- Sets `MIRRORET_APT_KEYRING` to the binary keyring path.

Identity: `MIRRORET_GPG_NAME`, `MIRRORET_GPG_EMAIL`. Bring your own key by
importing it into the homedir and setting `MIRRORET_GPG_KEYID`.

### What the key is not used for

Generating a key does **not** change the mirrored suites: their `Release`
files stay upstream-signed and the client configs keep pointing at the
distro keyring. Pointing `signed-by=` at the mirroret key for a mirrored suite
would make every `apt-get update` fail.

### `MIRRORET_APT_RESIGN=1`

Setting this makes the generated APT client configs use
`signed-by=${MIRRORET_APT_KEYRING}` and the install prints a warning that
mirroret does **not** re-sign anything itself. Only set it if you have your
own re-signing step for the mirrored `Release` files (for example because a
TLS-inspecting proxy re-signs upstream and clients would otherwise reject
the archive; see [PROXY_AND_CA.md](PROXY_AND_CA.md)). Clients then need the
key:

```bash
bash <(curl -fsSL http://SERVER:8080/config/import-mirroret-gpg-key.sh)
```

### RPM: `MIRRORET_RPM_GPGKEY_URL`

Set this to make generated `.repo` files use `gpgkey=<url>` instead of the
vendor key, e.g. `http://SERVER:8080/config/GPG-KEY.asc`, for packages you
signed yourself. Clients import it with `rpm --import <url>`.

---

## TLS (nginx HTTPS listener)

Opt-in. Without it, only HTTP on `MIRRORET_WEB_PORT` (8080) is served.

```bash
sudo ./install.sh --tls-self-signed                # 4096-bit RSA, 10 years,
                                                   # /etc/mirroret/tls/{cert,key}.pem
sudo MIRRORET_TLS_CERT=/etc/ssl/certs/server.crt \
     MIRRORET_TLS_KEY=/etc/ssl/private/server.key ./install.sh    # your own
```

When cert and key are in place, `install.sh` appends a TLS `server` block
on `MIRRORET_TLS_PORT` (8443) to the nginx vhost, opens that port in the
firewall alongside the others, and the Docker client config switches to
`https://SERVER:8443`. The TLS block serves the same file tree and the same
`/pip/`, `/npm/` and `/v2/` reverse proxies as the HTTP listener.

The self-signed certificate is not published over HTTP. Copy
`/etc/mirroret/tls/cert.pem` to clients yourself and trust it:

```bash
# Debian/Ubuntu
sudo cp cert.pem /usr/local/share/ca-certificates/mirroret.crt && sudo update-ca-certificates
# RHEL family
sudo cp cert.pem /etc/pki/ca-trust/source/anchors/mirroret.crt && sudo update-ca-trust extract
# Docker, per registry endpoint
sudo install -D cert.pem /etc/docker/certs.d/SERVER:8443/ca.crt && sudo systemctl restart docker
```

---

## Docker registry

The registry listens on **all interfaces** on `MIRRORET_DOCKER_REGISTRY_PORT`
(5000, `http.addr: :5000`) over plain HTTP, and nginx additionally proxies
`/v2/` on 8080 and, with TLS, on 8443.

- Without TLS the generated `docker-daemon.json` lists `SERVER:5000` in
  `insecure-registries`; dockerd refuses an `http://` mirror otherwise.
- With TLS it points `registry-mirrors` at `https://SERVER:8443` with no
  insecure entry.
- `MIRRORET_FIREWALL_SOURCE` is the way to restrict who can reach port 5000.

In `cache` mode the registry rejects pushes. In `hosted` mode it accepts
`docker push` from anyone who can reach the port; restrict it by subnet.

---

## pip and npm

pypiserver (8081) and Verdaccio (4873, bound to `MIRRORET_NPM_BIND_ADDR`,
default `0.0.0.0`) serve plain HTTP. Both are also reachable through nginx
as `/pip/` and `/npm/`, on 8443 when TLS is on.

Verdaccio requires `npm login` before `npm publish` unless
`MIRRORET_NPM_ALLOW_ANON_PUBLISH=1`; `npm adduser` is refused unless
`MIRRORET_NPM_ALLOW_SELF_REGISTER=1`.

---

## Restricting access

By subnet, at install time:

```bash
sudo MIRRORET_FIREWALL_SOURCE=10.0.0.0/8 ./install.sh
```

Rules are written for whichever firewall is **running** (ufw, firewalld,
iptables). See [NETWORK_ACCESS.md](NETWORK_ACCESS.md).

### nginx basic authentication

The vhost is regenerated on every `install.sh` run, so put the auth
directives in a separate include or re-apply after upgrades.

```bash
sudo htpasswd -c /etc/nginx/.htpasswd repouser    # apache2-utils / httpd-tools
```

Vhost: `/etc/nginx/sites-available/mirroret-unified` (Debian) or
`/etc/nginx/conf.d/mirroret-unified.conf` (RHEL). The generated APT location
for a flavor looks like this in `mirror` mode:

```nginx
location /ubuntu/ {
    alias /srv/mirroret/apt/ubuntu/;
    autoindex on;
}
```

and like this in `hybrid` / `cache` mode:

```nginx
location /ubuntu/ {
    root /srv/mirroret/apt/;
    try_files $uri @mirroret_cache;
    autoindex on;
}
```

Add to the block you want protected:

```nginx
    auth_basic "Repository Access";
    auth_basic_user_file /etc/nginx/.htpasswd;
```

then `sudo nginx -t && sudo systemctl reload nginx`. apt clients need the
credentials in the URL or in `/etc/apt/auth.conf.d/`.

The generated vhost already denies `/logs`, `/scripts`, `/staging`,
`/engines`, `/backups` and `/targets` under the base directory.

---

## Privilege model

| Process | Runs as | Notes |
|---|---|---|
| nginx | distro nginx user | read-only on the data tree |
| pypiserver | `mirroret-pip` | `ReadWritePaths` limited to `pip/`, `staging/`, `approved/` |
| Verdaccio | `mirroret-npm` | `/etc/verdaccio`, `npm/approved` |
| Docker registry | OS package user, or the container | |
| `mirroret-cache` | root | must write the mirror tree; bound to 127.0.0.1, `ProtectSystem=full`, `ReadWritePaths` = base dir |
| sync scripts (cron) | root | |

`install.sh`, `mirroretctl` state-changing commands and `uninstall.sh` require root.

---

## Audit trail

```
/var/log/nginx/mirroret-unified-access.log
/var/log/nginx/mirroret-unified-tls-access.log      # TLS listener
journalctl -u pypiserver  -u verdaccio  -u mirroret-cache
/srv/mirroret/logs/sync-*.log                        # one file per sync run
```

`mirroret-collect.sh` / `mirroretctl report` redact proxy credentials and
tokens before writing.
