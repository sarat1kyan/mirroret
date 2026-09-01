# Client configuration

How a client machine is pointed at a mirroret server, for APT, RPM, pip,
npm and Docker.

The supported way is the published bootstrap script (section 1). Sections 2
onwards explain what it does and how to do the same by hand. There are no
`trusted=yes` / `gpgcheck=0` shortcuts here: mirrored packages keep their
upstream signature and the client verifies it with the keyring it already
has. Insecure client configs are only generated when the **server** was
installed with `--insecure` / `MIRRORET_*_INSECURE=1`.

Replace `SERVER` with the mirror's IP or hostname. The HTTP port is 8080
unless `MIRRORET_WEB_PORT` was changed.

---

## 1. The bootstrap script: `setup-mirror-client.sh`

The server publishes `scripts/setup-mirror-client.sh` at
`http://SERVER:8080/config/setup-mirror-client.sh`. On each client:

```bash
curl -fsSL -o /tmp/setup-mirror-client.sh \
    http://SERVER:8080/config/setup-mirror-client.sh
sudo bash /tmp/setup-mirror-client.sh --server SERVER
```

What it does:

1. Detects the distribution and release from `/etc/os-release`.
2. Fetches the matching published config (`<flavor>-<codename>.list` or
   `<flavor><major>.repo`). If the server does not publish a config for this
   exact release it lists what is available and stops rather than guessing.
3. Backs up every file it is about to change into a timestamped directory,
   then installs the mirror config and disables the upstream repositories.
4. Installs `/etc/pip.conf` and the system-wide npm registry setting when the
   server publishes `pip.conf` / `.npmrc`; configures the Docker registry
   mirror only with `--docker`.
5. Verifies: runs `apt-get update` / `dnf makecache`, then downloads a
   package pinned to the version the mirror's own index lists. A 404 on
   optional metadata is reported as a warning (apt itself ignores those);
   a failed pinned download is fatal.

`--rollback` restores the most recent backup and removes the mirror config.

Options (from `setup-mirror-client.sh --help`):

| Flag | Meaning |
|---|---|
| `--server HOST[:PORT]` | mirror server (required unless `--rollback`) |
| `--release NAME` | override the detected release (e.g. `jammy`, `9`) |
| `--config NAME` | use this exact published config, e.g. `debian-bookworm.list` or `rocky9.repo`; overrides all detection |
| `--keep-upstream` | install the mirror config but leave the upstream repos enabled |
| `--no-pip` | skip `/etc/pip.conf` |
| `--no-npm` | skip the system-wide npm registry setting |
| `--docker` | also configure the Docker registry mirror |
| `--rollback` | restore the most recent backup and remove the mirror config |
| `-y`, `--yes` | non-interactive |
| `--dry-run` | show what would change, change nothing |
| `-h`, `--help` | usage |

---

## 2. Which config file is which

The server generates one config per mirrored target under
`/srv/mirroret/config/`, served at `http://SERVER:8080/config/`:

```
ubuntu-jammy.list      ubuntu-jammy.sources     # one-line and deb822 forms
ubuntu-noble.list      ubuntu-noble.sources
debian-bookworm.list   debian-bookworm.sources
ol9.repo  rocky9.repo  epel9.repo
pip.conf  .npmrc  docker-daemon.json
setup-mirror-client.sh
```

`debian-client.list` and `redhat-client.repo` are copies of the first
configured target, kept for older runbooks. List what a server publishes:

```bash
curl -s http://SERVER:8080/config/
mirroretctl client list        # on the server
```

---

## 3. APT (Ubuntu / Debian) by hand

```bash
. /etc/os-release
sudo curl -fsSL -o /etc/apt/sources.list.d/mirroret.list \
    "http://SERVER:8080/config/${ID}-${VERSION_CODENAME}.list"

# Disable the upstream entries, or apt keeps reaching the internet.
sudo mv /etc/apt/sources.list /etc/apt/sources.list.disabled-by-mirroret
sudo rm -f /etc/apt/sources.list.d/ubuntu.sources \
           /etc/apt/sources.list.d/debian.sources     # deb822 hosts

sudo apt-get update
apt-cache policy bash | head -5      # must name SERVER
```

Use the `.sources` file instead of `.list` if the client already uses deb822
(Ubuntu 24.04, Debian 12 default).

**No key to import.** The mirrored `Release`/`InRelease` files are the
upstream files, byte for byte, so the client verifies them with the
`ubuntu-archive-keyring` / `debian-archive-keyring` it already ships. The
generated config carries `signed-by=` pointing at that stock keyring and an
`arch=` list pinned to what the mirror actually published.

If a config carries `signed-by=/etc/apt/keyrings/mirroret.gpg` the server was
configured with `MIRRORET_APT_RESIGN=1` and the mirror's key must be imported
first - see [SECURITY.md](SECURITY.md).

### `apt-get update` reports 404 on a `Packages` file

The config advertises a suite the server has not published yet. On the
**server**:

```bash
mirroretctl client verify      # names the unpublished suites
sudo mirroretctl sync apt
```

### Undo

```bash
sudo rm /etc/apt/sources.list.d/mirroret.list
sudo mv /etc/apt/sources.list.disabled-by-mirroret /etc/apt/sources.list
sudo apt-get update
```

(or `setup-mirror-client.sh --rollback` if the script did the enrolment).

---

## 4. RPM (Oracle / Rocky / Alma / CentOS Stream / RHEL / Fedora / EPEL) by hand

```bash
# One file per mirrored target, named <flavor><major>.repo:
curl -s http://SERVER:8080/config/ | grep -o '[a-z0-9]*\.repo'
sudo curl -fsSL -o /etc/yum.repos.d/mirroret.repo http://SERVER:8080/config/ol9.repo

# Disable the upstream repos, or dnf keeps reaching the internet.
sudo dnf config-manager --set-disabled "*"
sudo dnf config-manager --set-enabled "mirroret-*"

sudo dnf clean all && sudo dnf repolist     # only mirroret-* enabled
sudo dnf install -y bash                    # downloads from the mirror
```

**No key to import.** Mirrored RPMs keep their vendor signature and the
generated `.repo` sets `gpgcheck=1` with `gpgkey=` pointing at the vendor key
already present in `/etc/pki/rpm-gpg/` (`RPM-GPG-KEY-oracle`,
`RPM-GPG-KEY-Rocky-9`, ...). Only when the server sets
`MIRRORET_RPM_GPGKEY_URL` does the config point at a URL instead.

**Do not add `repo_gpgcheck=1`.** A filtered mirror (an arch subset, or the
default newest-only) has locally rebuilt `repomd.xml`, so upstream's
detached signature on it does not apply. Package signatures are untouched.

### `dnf` says "Cannot download repomd.xml"

That repo has not been published yet. On the **server**:

```bash
mirroretctl client verify
sudo mirroretctl sync rpm
```

### Undo

```bash
sudo rm /etc/yum.repos.d/mirroret.repo
sudo dnf config-manager --set-enabled "*"   # or restore your backup of /etc/yum.repos.d
sudo dnf clean all
```

---

## 5. pip

The generated `pip.conf`:

```ini
[global]
index-url = http://SERVER:8081/simple/
trusted-host = SERVER
```

`trusted-host` is required by pip for any plain-HTTP index and does not
disable anything that HTTP provides. Install it system-wide:

```bash
sudo curl -fsSL -o /etc/pip.conf http://SERVER:8080/config/pip.conf
pip3 download --no-deps -d /tmp/t requests    # proves the index answers
```

Per command instead: `pip install --index-url http://SERVER:8081/simple/ --trusted-host SERVER <pkg>`.

---

## 6. npm

The generated `.npmrc` is one line:

```
registry=http://SERVER:4873/
```

npm does not read `/etc/npmrc`. The system-wide file is
`$(npm prefix -g)/etc/npmrc`, which is what the bootstrap script writes.
Per user:

```bash
npm config set registry http://SERVER:4873/
npm view express version        # must answer through the mirror
```

With approval mode on the server, packages nobody approved return 404
instead of being fetched from npmjs - see [OPERATIONS.md](OPERATIONS.md).

---

## 7. Docker

The generated `docker-daemon.json` depends on the server's mode:

| Server state | Content |
|---|---|
| cache mode, no TLS | `{"registry-mirrors": ["http://SERVER:5000"], "insecure-registries": ["SERVER:5000"]}` |
| cache mode, TLS ready | `{"registry-mirrors": ["https://SERVER:8443"]}` |
| hosted mode, no TLS | `{"insecure-registries": ["SERVER:5000"]}` |
| hosted mode, TLS ready | `{}` |

`insecure-registries` appears without TLS because dockerd refuses an
`http://` mirror otherwise; it is not a mirroret shortcut. Apply:

```bash
sudo curl -fsSL -o /etc/docker/daemon.json http://SERVER:8080/config/docker-daemon.json
sudo systemctl restart docker
docker pull alpine        # cache mode: pulled through the mirror
```

Hosted mode has no mirror; pull explicitly with `docker pull SERVER:5000/<image>`.
The bootstrap script does this step only with `--docker`.

---

## 8. Locking a client to the mirror

The scripts above disable the upstream sources. To additionally refuse
packages from any other origin on an APT client:

```
# /etc/apt/preferences.d/mirroret-only
Package: *
Pin: origin "SERVER"
Pin-Priority: 1000

Package: *
Pin: origin *
Pin-Priority: -1
```

---

## 9. Checking from the server side

```bash
mirroretctl client list        # every generated config and its URL
mirroretctl client show ubuntu-noble.list
mirroretctl client verify      # config advertises only published suites/repos
mirroretctl client simulate    # resolve AND download with a throwaway dnf config
mirroretctl serve              # every HTTP endpoint answers locally
```
