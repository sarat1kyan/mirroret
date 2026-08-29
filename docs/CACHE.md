# Storage modes: mirror, hybrid, cache

A full mirror downloads every package a distro publishes, whether anyone
installs it or not. That is the right answer for an air-gapped site and the
wrong answer almost everywhere else, because of the arithmetic:

| What | Disk |
|---|---|
| Ubuntu noble, `main` + `restricted`, amd64 | ~400 GB |
| ...plus jammy | ~800 GB |
| ...plus i386 | ~850 GB |
| What a fleet of 40 machines actually installs | 10-30 GB |

The gap is disk rent on files nobody will ever ask for.

`MIRRORET_APT_MODE` picks how packages are stored. Set it in
`/etc/mirroret/mirroret.conf`, or answer the question the first-run wizard
asks, then `sudo ./install.sh --upgrade`.

## The three modes

### `mirror` — everything up front

Every package is downloaded ahead of time. Fully offline once synced; a
client can install anything the archive has with the WAN link unplugged.
Costs the numbers in the table above.

Choose this if the site is genuinely air-gapped, or disk is free and
predictable beats small.

### `hybrid` — indices up front, packages on demand *(recommended)*

The full signed index tree is mirrored (a couple of GB). No packages are.
When a client asks for a `.deb` that is not on disk, the cache fetches that
one file from upstream, stores it, and serves it. Every later client gets it
from disk at LAN speed.

- `apt-get update` is instant and works even when upstream is unreachable,
  because the indices are local.
- The first install of a given package pays one upstream fetch. The
  hundredth pays nothing.
- Disk converges on what the fleet actually uses.

This is the right default for almost everyone.

### `cache` — nothing up front

Indices and packages are both fetched on demand and cached. The smallest
possible footprint, and there is no sync to schedule at all.

The tradeoff is that a *cold* `apt-get update` needs upstream to be
reachable. Once an index has been fetched once it is served locally and
revalidated on a TTL, and if upstream goes away the last known-good copy is
still served — but a machine that has never talked to this mirror before
cannot bootstrap while the WAN is down.

## Switching modes

```bash
sudo sed -i 's/^MIRRORET_APT_MODE=.*/MIRRORET_APT_MODE="hybrid"/' \
    /etc/mirroret/mirroret.conf
sudo ./install.sh --upgrade
sudo mirroretctl sync apt
```

Switching to `hybrid` or `cache` does **not** delete packages already on
disk. They stay and continue to be served as cache hits. Switching back to
`mirror` and running a sync backfills whatever is missing.

## Does this weaken security?

No, and it is worth being precise about why, because a cache between apt and
the archive sounds like it should.

- `InRelease` / `Release` are passed through byte-for-byte, so the client
  verifies the **upstream** signature against its own keyring exactly as it
  would against `archive.ubuntu.com`. mirroret never re-signs anything.
- That signed `Release` carries the SHA256 of every `Packages` index, and
  each `Packages` index carries the SHA256 of every `.deb`.
- The client checks both chains itself.

So a corrupted or substituted cache entry is *caught by apt*, not trusted by
it. The cache is a transport optimisation, never a trust anchor. This is the
same property that lets the full mirror work without a signing key.

## How it fits together

```
client ──> nginx :8080 ──> file on disk?
                            ├── yes ──> served by nginx, full speed
                            └── no  ──> mirroret-cache :8082
                                          └── fetch upstream (via proxy),
                                              store, stream to client
```

nginx answers every hit itself with `try_files`, so once the cache is warm
Python is not in the request path at all.

### What the daemon handles

**Concurrent requests are coalesced.** Forty machines whose upgrade cron
fires on the same minute produce *one* upstream fetch, not forty. Clients
that arrive while a download is in flight tail the partial file as it is
written, so they start receiving bytes immediately rather than blocking
until it completes.

**Package files are cached forever; indices are revalidated.** A package's
bytes never change upstream — a rebuild gets a new version and therefore a
new filename — so once cached it needs no further checking. Indices are
revalidated on a TTL with a conditional GET, so an unchanged `InRelease`
costs a 304 and no body.

**Upstream outages serve stale rather than failing.** If the archive or the
corporate proxy is unreachable, the last known-good index is served. A flaky
proxy should not take every client's package manager down with it.

**Split archives resolve correctly.** Ubuntu serves `noble-security` from
`security.ubuntu.com` while clients see one `/ubuntu/` prefix, and Debian's
security archive is a different path on the same host. Each route carries an
ordered list of upstreams and the first that has a given path wins.

## Operating it

```bash
mirroretctl cache status    # running? hit rate? how much came from upstream?
mirroretctl cache routes    # which upstreams each prefix resolves to
mirroretctl cache size      # disk per flavor, and free space
sudo mirroretctl cache gc   # apply a changed size cap now
```

`cache status` reports a **served local** percentage — the share of client
requests that never left the machine. That is the number that says whether
on-demand is paying off. Expect it to be low on day one and to climb past
90% within a week or two of normal use.

## Capping disk

```bash
MIRRORET_CACHE_MAX_SIZE_GB="120"
```

Above the cap, least-recently-used **package** files are evicted. Indices are
never evicted: they are a rounding error in size terms and dropping one just
forces an immediate refetch on the next `apt-get update`. An evicted package
is refetched on demand if something asks for it again, so eviction costs
latency, never correctness.

`0` (the default) means no cap — keep everything that has been asked for.

## Other tunables

| Variable | Default | What it does |
|---|---|---|
| `MIRRORET_APT_MODE` | `mirror` | `mirror`, `hybrid` or `cache` |
| `MIRRORET_CACHE_PORT` | `8082` | loopback port the daemon binds |
| `MIRRORET_CACHE_MAX_SIZE_GB` | `0` | LRU cap; 0 = unlimited |
| `MIRRORET_CACHE_METADATA_TTL` | `300` | seconds before revalidating an index |
| `MIRRORET_CACHE_CONFIG` | `/etc/mirroret/cache.json` | generated route table |

The route table is generated from `MIRRORET_APT_TARGETS` by
`install.sh --upgrade`. Editing it by hand works but will be overwritten on
the next upgrade; change the targets instead.

## Troubleshooting

**Clients 404 on packages.** Check the daemon is up and routing:

```bash
mirroretctl cache status
mirroretctl cache routes
journalctl -u mirroret-cache -n 50
```

**Everything 502s behind a corporate proxy.** The daemon reaches upstream the
same way the sync scripts do, through `MIRRORET_PROXY` in
`/etc/mirroret/mirroret.conf`. A proxy that only permits `CONNECT` to :443
will refuse plain HTTP to the archives, so also set:

```bash
MIRRORET_APT_SCHEME="https"
```

and re-run `sudo ./install.sh --upgrade` so both the mirror and the cache
pick up the change.

**A sync in hybrid mode reports "downloaded 0".** That is correct — hybrid
deliberately downloads no packages. The line to check is
`published: dists/<suite>`, and `mirroretctl verify` confirms the index tree
is complete.
