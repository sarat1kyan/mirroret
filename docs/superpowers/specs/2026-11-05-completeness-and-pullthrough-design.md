# mirroret: completeness, freshness, and new pull-through subsystems

Design document. Status: **approved 2026-11-05** (owner: "cook… till
everything perfectly cook"). Date: 2026-11-05.

Builder-check (2026-11-05) raised four blocking questions; all were settled
as builder/architecture calls that do not change what the owner asked for
(never false not-found; updates appear within TTL; `repo_gpgcheck` keeps
working). The settlements are inlined where they apply, each tagged "my
call": (1) RPM daemon route mapping — one daemon rooted at `${base_dir}`
with longest-prefix route keys (§1d); (2) APT client config widens to the
full component set via the published manifest (§1a); (3) RPM metadata-only
forces `filtered=False`, publishes signed repodata verbatim, and the `.repo`
emits `repo_gpgcheck=1` only in that mode (§1c); (4) RPM hybrid/cache
requires the native engine (§1c).

## Intent and the why

mirroret is one server a Linux fleet installs packages from. Two symptoms
make it feel broken to the people using it, and two capabilities are
missing that the owner wants:

1. **"Package not found."** A client runs `apt install X` / `dnf install X`
   and the package is not there, even when it exists upstream.
2. **"No updates."** `apt-get update` / `dnf upgrade` shows nothing new
   even when upstream has published updates.
3. **Docker** should let the owner add images manually or have them pulled,
   and clients should get those images from the mirror server.
4. **Git** should work: clients clone/pull public upstream repos through the
   mirror, cached and served at LAN speed.

The owner's instruction was "make sure everything will work." The guiding
principle for this design: **a client should never get a false "not found"
and never be pinned to stale metadata.** If the mirror does not already
have a thing a client legitimately asks for, it fetches it from upstream,
caches it, and serves it — the miss is invisible except for being slightly
slower the first time.

### Decisions the owner made (not the builder's to change)

- **Git = pull-through mirror of upstream repos.** Clients
  `git clone http://SERVER/git/github.com/org/repo`; the server serves it if
  cached, otherwise fetches from upstream, caches, and serves. Not an
  internal git host — no pushing your own repos (that is explicitly out of
  scope for this work).
- **Server is always online.** The mirror server can always reach upstream,
  so pull-through-on-miss is acceptable for every subsystem. No air-gapped
  server. (Individual clients still benefit from the LAN mirror; the design
  does not assume clients are offline, but it does not need to pre-mirror
  everything to protect an offline server.)
- **First deliverable = fix not-found and no-updates, for APT and RPM.**
  Docker and Git come after.

## Root causes (verified in the code)

**Not-found, APT hybrid mode.** The published index is filtered to
`MIRRORET_APT_COMPONENTS` (e.g. `main restricted`). A package in `universe`
is not listed in the index, so apt reports not-found — even though the
pull-through cache could fetch the `.deb`. Fallthrough only works for
packages the index lists. (`engines/mirroret_apt.py`
`_entry_matches_filters`; `self.components`.)

**Not-found, RPM any mode.** `lib/cache.sh` `generate_cache_config` emits
**APT routes only** (`"kind": "apt"`). There is no RPM route, and
`lib/nginx.sh` serves the RPM tree (`/redhat/`, flavor dirs) with
`alias ... autoindex on` and no `try_files @mirroret_cache`. So RPM has no
pull-through at all. Combined with the default `MIRRORET_RPM_NEWEST_ONLY=1`
(a filtered mirror whose repodata is rebuilt to match disk), any
not-newest or excluded-arch package is simply absent with no way to fetch
it. (`lib/cache.sh:66-162`; `lib/nginx.sh:181-260`; `lib/rpm.sh:111-114`.)

**No-updates, hybrid and mirror modes.** In `cache` mode, `dists/` is
always proxied through the daemon (regex location in `lib/nginx.sh:232`),
which applies a TTL and a conditional GET, so updates appear within the
TTL. In **hybrid** and **mirror** modes, `dists/` is served straight off
disk (`try_files $uri @mirroret_cache` resolves to the on-disk index that
the nightly sync wrote), so the daemon is never asked to revalidate.
Clients are pinned to whatever the last **nightly** sync produced; between
syncs, or when a sync fails, new upstream releases are invisible.
(`lib/nginx.sh:236-248`.)

## Goals

- A client asking for any package that exists in a mirrored suite/repo gets
  it — from disk if cached, otherwise fetched on demand — in hybrid and
  cache modes, for both APT and RPM.
- Published metadata reflects upstream within a bounded, configurable
  staleness window (default 5 minutes) in hybrid and cache modes, without
  waiting for the nightly sync.
- RPM gets a pull-through path equivalent to APT's.
- Docker: images can be seeded manually and are pulled through on demand;
  clients pull only from the mirror.
- Git: public upstream repos clone/pull through the mirror, cached.
- The HIGH-severity security holes that the "make everything work" goal
  implicitly includes are closed, not widened, by this work.

## Non-goals

- Internal git hosting (push your own repos). Out of scope this round.
- Changing the full-`mirror` mode's offline guarantee. Mirror mode stays
  "download everything up front, fully offline."
- Re-signing any metadata. The trust model (mirror never re-signs; client
  verifies upstream signatures) is unchanged in every phase.
- Replacing the cache daemon or the engines wholesale.

## Anti-goals (these would make it a failure even if it "works")

- A fix that makes `apt-get update` or package install **slower** on the
  common warm-cache path. Hits must still be served off disk by nginx.
- Weakening verification anywhere: no phase may introduce a path where a
  client installs a package whose signature it did not verify, outside the
  already-existing, explicitly-flagged `--insecure` modes.
- A pull-through that masks a real upstream outage as a silent empty
  result. A miss that cannot be satisfied must surface as an error the
  client sees, not a false 404 that looks like "no such package."

## Constraints

- Engines stay **stdlib-only Python 3**, runnable on RHEL 8's Python 3.6.
- No new mandatory system dependency for Phase 1. (Git phase may require the
  `git` binary on the server; Docker phase uses the existing registry.)
- Backward compatible: an existing `mirror`-mode install keeps working
  unchanged; new behaviour is opt-in by mode, with safe defaults.
- All generated files keep the `mirroret-managed` marker and `--upgrade`
  regeneration contract.

---

## Phase 1 — APT + RPM: never false-not-found, never stale (the first deliverable)

### 1a. APT: publish the full index in hybrid/cache

In hybrid and cache modes, publish **every component the suite advertises**,
not just `MIRRORET_APT_COMPONENTS`. The package files stay on-demand, so the
disk cost is only the larger index tree (a few GB, not hundreds). This makes
every package resolvable, so the pull-through cache can actually serve it.

- Engine (`mirroret_apt.py`): add a spec flag `all_components` (and
  `--all-components`). When set, after fetching and verifying `Release`, set
  `self.components = release.components` (the suite's own `Components:`
  field) before selecting entries. `MIRRORET_APT_COMPONENTS` continues to
  govern `mirror` mode (where disk is the constraint).
- Wiring (`lib/apt.sh`, `lib/targets.sh`): when
  `MIRRORET_APT_MODE` is `hybrid` or `cache`, set `all_components` in the
  generated APT spec. Keep `MIRRORET_APT_COMPONENTS` as an override for
  operators who deliberately want a narrower index.
- **Client config must widen to match (builder-check settlement, my
  call).** apt only resolves packages in the components the *client* config
  lists, so publishing a full index is not enough on its own — the generated
  `.list`/`.sources` Components field must also list the full set in
  hybrid/cache, or the headline acceptance ("`main`-only install of a
  `universe` package succeeds") fails. The client-config generator
  (`lib/apt.sh:866,908,917`) must, in hybrid/cache, read the full component
  list from the engine's published manifest
  (`dists/<suite>/.mirroret-manifest.json`, which already records
  `components` — `engines/mirroret_apt.py:785-795`) rather than from the
  `MIRRORET_APT_COMPONENTS` / flavor-default shell source. The manifest is
  the authoritative "what the suite actually advertises," written from the
  live signed `Release`; the flavor defaults can disagree with it and must
  not be the source here. If no manifest exists yet (first install before
  the first sync), fall back to the flavor defaults and let the next sync
  correct the config via `--upgrade`.

### 1b. APT: revalidate metadata in hybrid too

Route `dists/` through the daemon in **hybrid** mode exactly as cache mode
already does, so metadata is revalidated on a TTL instead of frozen at the
last nightly sync. The daemon serves the on-disk index when fresh and does a
conditional GET to upstream when the TTL has expired; the pool stays served
off disk.

- `lib/nginx.sh`: apply the `location ~ ^/<dir>/dists/` daemon route for
  `hybrid` as well as `cache` (currently gated on
  `MIRRORET_APT_MODE == "cache"` at `lib/nginx.sh:223`).
- The nightly metadata-only sync becomes **cache warming**, not the sole
  freshness mechanism. It still runs; it is no longer load-bearing for
  "do updates appear."
- `mirror` mode is unchanged (fully static by design; freshness comes from
  the nightly full sync, which is the mode's whole contract).

### 1c. RPM: add a metadata-only + pull-through path

Give RPM the equivalent of APT hybrid: publish full upstream repodata, skip
downloading packages, and let the daemon fetch each `.rpm` on demand.

- Engine (`mirroret_rpm.py`): add `--metadata-only` (and spec
  `metadata_only`). **Correction from builder-check (my call):** there is no
  `KEEP_UPSTREAM_METADATA` path *in the engine* — that flag lives only in
  the reposync shell path (`lib/rpm.sh:422`). The engine keeps upstream
  `repomd` verbatim only when `self.filtered` is False, and `self.filtered`
  is computed as `len(packages) != seen` (`mirroret_rpm.py:821`), so a
  download-nothing run would compute `filtered=True` and rewrite `repomd`
  down to **zero** packages — the opposite of what we want. Therefore
  `--metadata-only` must: force `self.filtered = False`, fetch **all**
  referenced metadata, publish `repomd` + `repomd.xml.asc` and the metadata
  files **verbatim** (the `repomd_raw`/`asc` publish path,
  `mirroret_rpm.py:657-667`), and **skip** the `.rpm` download step
  (`_download`). Result: clients see the complete, signed upstream package
  list and the daemon fetches each `.rpm` on demand.
- **Client `.repo` must enable `repo_gpgcheck=1` in this mode (my call).**
  The generator today deliberately omits `repo_gpgcheck` with a comment that
  filtered mirrors cannot support it (`lib/rpm.sh:867-871`). Make that
  mode-aware: emit `repo_gpgcheck=1` **only** in metadata-only mode (where
  upstream signed repodata is served verbatim). In filtered `mirror` mode it
  stays omitted, exactly as now. `gpgcheck=1` (vendor package signatures) is
  on in every mode regardless.
- Routes (`lib/cache.sh`): extend `generate_cache_config` to emit RPM
  routes (`"kind": "rpm"`) from the resolved RPM targets, keyed on the RPM
  flavor directory, with the same upstream list the RPM sync uses. Decide
  the client-facing prefix to match what the generated `.repo` `baseurl`
  already uses (`/redhat/...` and per-flavor dirs — the builder confirms the
  exact prefix against `lib/rpm.sh` client-config generation and keeps them
  identical).
- Wiring (`lib/nginx.sh`): for RPM flavor dirs, emit
  `try_files $uri @mirroret_cache` (and a `repodata/` daemon route for TTL
  revalidation, mirroring the APT `dists/` treatment) when
  `MIRRORET_APT_MODE`/a new `MIRRORET_RPM_MODE` is hybrid or cache.
- Mode variable: introduce `MIRRORET_RPM_MODE` (`mirror|hybrid|cache`,
  default `mirror` for backward compatibility) rather than overloading
  `MIRRORET_APT_MODE` onto RPM. The wizard offers it alongside the APT mode.
- **RPM hybrid/cache requires the native engine (builder-check settlement,
  my call).** `--metadata-only` exists only on the native Python engine; the
  reposync path (`lib/rpm.sh:613-646`) has no equivalent. So
  `MIRRORET_RPM_MODE=hybrid|cache` **requires** `_rpm_resolve_engine` to
  select native. Validation (`validate_cache_mode`'s RPM counterpart, and
  the wizard) must force native and hard-error with a clear message if
  reposync would otherwise be chosen (repo not in catalog, or `python3`
  absent). reposync stays `mirror`-mode only. No reposync metadata-only
  equivalent is built this round.

### 1d. The daemon (corrected after builder-check — my call)

The earlier claim "no daemon logic change for RPM" was wrong. Two real
problems:

- **Route key is single-segment.** `resolve()` keys a route on the first
  path segment only (`parts = clean.split("/", 1)`;
  `route = self.routes.get(parts[0])`, `mirroret_cache.py:320-327`). That
  fits APT (`/ubuntu/pool/...` → route `ubuntu`). It does **not** fit RPM:
  the client baseurl is `/redhat/<flavor>/<major>/<repo>/...`
  (`lib/rpm.sh:552,876`), so the first segment is always `redhat`, and each
  `<flavor>/<major>/<repo>` has a *different* upstream whose internal layout
  bears no relation to the client-tree path.
- **Cache dir is hardcoded to `${base_dir}/apt`** (`lib/cache.sh:197`), but
  RPM is served from `${base_dir}/redhat/mirror/...` (`lib/nginx.sh:83`).
  A miss stored under `apt/redhat/...` is nowhere nginx looks, so every
  request re-misses forever.

**Resolution (my call): one daemon rooted at `${base_dir}`, longest-prefix
route matching.** Change `--cache-dir` to `${base_dir}` (not
`${base_dir}/apt`). Change `resolve()` to match the **longest** configured
route prefix against the request path, not just the first segment, so routes
like `apt/ubuntu`, `redhat/mirror/ol/9/baseos`, and
`redhat/mirror/ol/9/appstream` coexist, each mapping its client-tree prefix
to its own upstream. `generate_cache_config` emits one route per RPM repo
keyed on the full client-tree prefix with that repo's upstream URL(s). The
APT routes move from bare `ubuntu` to `apt/ubuntu` to match the on-disk
tree; nginx `root`/`try_files` for APT is adjusted so `$uri` still resolves
under `${base_dir}` (APT tree is at `${base_dir}/apt/<dir>/...`). The daemon
keeps classifying `.rpm` as immutable and `repodata/` as metadata
(`is_immutable`, `_METADATA_DIR_RE`) unchanged. Multi-upstream
(`-security`-style split) candidate lists still apply per route.

This is a backward-compatible change *as long as* the route-key and
cache-dir move are done together with the nginx `root` adjustment; the plan
sequences them as one atomic step with its own tests
(`test_cache_wiring.bats`, a new `resolve()` longest-prefix unit test).

### Phase 1 acceptance

- On a hybrid APT mirror configured with `main` only, `apt-get install` of a
  `universe` package succeeds (index lists it; daemon fetches the `.deb`).
- On a hybrid/cache RPM mirror, `dnf install` of a not-newest or
  other-component package succeeds via pull-through.
- After upstream publishes a new `Release`/`repomd`, a client
  `apt-get update` / `dnf makecache` sees it within `metadata_ttl`
  (default 300 s) without a new nightly sync.
- Warm-cache installs are still served off disk by nginx (no latency
  regression on the common path).
- `repo_gpgcheck=1` still works for RPM in metadata-only mode (upstream
  repodata kept verbatim); client signature verification is unchanged for
  APT.
- Existing `mirror`-mode installs behave exactly as before.

---

## Phase 2 — Docker: seed + pull-through, clients pull from the mirror

Build on the existing registry (`lib/docker_registry.sh`). Deliver:

- **Pull-through (cache mode)** reliably serving upstream images clients
  request, so `docker pull SERVER:5000/library/nginx` works without
  pre-seeding.
- **Manual seeding** so the owner can add images deliberately
  (the existing `sync-docker-images.sh` + an image list), and a
  `mirroretctl docker add <image>` convenience.
- Client config that points Docker at the mirror
  (`docker-daemon.json` already generated).

Known issue to resolve here (from the audit): the registry binds
`0.0.0.0:5000` with no auth. Phase 2 binds it to loopback behind nginx
`/v2/` (already proxied) and/or adds htpasswd auth, and validates the image
list against `^[A-Za-z0-9._/:@-]+$` before it reaches the generated sync
script (command-injection fix). Detailed design written at the start of
Phase 2.

## Phase 3 — Git: pull-through clone/pull of upstream repos

New subsystem. Clients `git clone http://SERVER/git/<host>/<path>`; the
server serves a cached mirror clone or creates/updates one from upstream on
demand, then serves it.

Approach to be detailed at Phase 3 start; the leading candidate is a
smart-HTTP front: nginx routes `/git/` to `git-http-backend` over a local
mirror-clone store, with an on-miss hook that runs
`git clone --mirror <upstream>` (or `git remote update`) into the store,
bounded by the same disk floor and proxy/CA handling the other engines use.
Freshness via a TTL on `git remote update`, mirroring the metadata-TTL
model. Requires the `git` binary on the server (new dependency, gated to
the Git feature). Trust note: git has no upstream signature equivalent to
APT/RPM, so this is a convenience/availability cache, not an integrity
boundary — documented as such.

## Phase 4 — Close the HIGH-severity security holes

Folded in because "make everything work" includes not shipping the
following. Sequenced last only because Phase 1 is the owner's priority; a
builder may pull individual items earlier when touching the same file.

- **Client enrollment over plain HTTP piped to `sudo bash`**
  (`install.sh:1151`, `scripts/setup-mirror-server.sh:875`): serve the
  bootstrap over HTTPS and verify a pinned SHA256, or ship a detached
  signature the client checks before executing.
- **Client trusts any config the server/MITM returns**
  (`scripts/setup-mirror-client.sh`): require HTTPS + pinned cert for
  enrollment; client hard-refuses a config containing
  `trusted=yes`/`gpgcheck=0` unless a local `--insecure` is passed.
- **Config is `source`d as root code** (`install.sh:197,385`,
  `common.sh:117`, `mirroretctl:39`) and **the `bash -c` conf-path
  injection** (`mirroretctl:1210`, `MIRRORET_CONF` → command execution):
  parse `KEY=value` with a whitelist instead of sourcing; pass paths as
  argv, never interpolated into a `bash -c` string.
- **Registry binds `0.0.0.0` with no auth** — addressed in Phase 2.
- **Docker image-list command injection** — addressed in Phase 2.
- **Firewall opens all ports to the world by default; iptables path has no
  default-deny and does not persist** (`lib/firewall.sh:82,89`): default to
  a restricted source or a loud warning; add a DROP policy and persistence
  for the iptables path.

Full findings live in the two audit reports summarised to the owner on
2026-11-05; this phase gets its own detailed design before build.

---

## What is left to the builder

- Exact client-facing URL prefixes for RPM routes: read them off the
  generated `.repo` `baseurl` in `lib/rpm.sh` and make the cache routes and
  nginx locations match byte-for-byte. Do not invent a new prefix.
- Whether RPM freshness uses `MIRRORET_RPM_MODE` (recommended in this doc)
  or reuses `MIRRORET_APT_MODE`; the doc recommends a separate variable but
  the builder may unify if the wizard/UX is cleaner, as long as `mirror`
  stays the backward-compatible default.
- The precise TTL/`location` regex shapes, reusing the existing APT
  `dists/` machinery rather than inventing a parallel one.
- Test coverage: extend the existing BATS suites (`test_cache*.bats`,
  `test_rhel.bats`, `test_engines.bats`) and the Python engine tests to
  cover: full-component index selection, hybrid `dists/` revalidation wiring,
  RPM metadata-only publication keeping upstream repodata, and RPM
  pull-through route generation.
- Docs updates (`docs/CACHE.md`, `docs/MULTI-DISTRO.md`, README storage-mode
  section) to match the new hybrid/cache completeness and the RPM mode.

## Delivery order

Phase 1 (1a → 1b → 1c → 1d) first and shippable on its own. Then Phase 2
(Docker), Phase 3 (Git), Phase 4 (security) — each with its own short design
written at its start. Phase 4 items may be pulled forward opportunistically
when a builder is already editing the relevant file.
