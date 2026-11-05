# Phase 1: APT + RPM Completeness & Freshness Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** In hybrid/cache mode a client never gets a false "not found" and never sees stale metadata, for both APT and RPM.

**Architecture:** Publish the full index (APT: all components; RPM: full upstream repodata) so every package resolves, keep package payloads on-demand, and route metadata (`dists/`, `repodata/`) through the pull-through daemon on a TTL so updates appear without waiting for the nightly sync. The daemon moves to one instance rooted at `${base_dir}` with longest-prefix route matching so RPM repos (4-segment client prefixes) route alongside APT.

**Tech Stack:** stdlib-only Python 3 (3.6+ floor), bash, nginx, systemd, BATS tests.

**Spec:** `docs/superpowers/specs/2026-11-05-completeness-and-pullthrough-design.md`

## Global Constraints

- Engines stay stdlib-only Python 3, runnable on RHEL 8's Python 3.6. No new pip deps.
- No new mandatory system dependency in Phase 1.
- Backward compatible: an existing `mirror`-mode install behaves exactly as before. New behaviour is gated on `MIRRORET_APT_MODE` / `MIRRORET_RPM_MODE` being `hybrid` or `cache`; default of both stays `mirror`.
- Trust model unchanged: mirror never re-signs; client verifies upstream signatures. No new path installs an unverified package outside existing explicit `--insecure` modes.
- All generated files keep the `mirroret-managed` marker and the `--upgrade` regeneration contract.
- A warm-cache hit must still be served off disk by nginx (no latency regression on the common path).

## Review Focus

- **APT suite with a component upstream dropped between syncs** (`Components:` shrinks): `all_components` reads the live `Release`, so a removed component must not leave a stale client-config entry that 404s — pinned in Task 3 (manifest is regenerated each publish; client config reads current manifest).
- **RPM repo whose upstream omits `repomd.xml.asc`**: metadata-only must still publish and emit `repo_gpgcheck=1` only when the `.asc` is actually present — pinned in Task 5 (publish `.asc` only if fetched) and Task 10 (emit `repo_gpgcheck=1` only when the published repodata has an `.asc`).
- **Daemon request whose path matches two route prefixes** (`redhat/mirror/ol/9/baseos` vs a hypothetical `redhat/mirror/ol/9`): longest-prefix wins deterministically — pinned in Task 8.
- **Mode set to hybrid/cache while reposync engine would be selected** (repo not in catalog, or `python3` absent): must hard-error, not silently mirror — pinned in Task 6.
- **Cache-dir move with a pre-existing `mirror`-mode tree on disk**: APT `$uri` must still resolve under the new `root` after routes move from `ubuntu` to `apt/ubuntu` — pinned in Task 8 and Task 4 (nginx `root` points at `${base_dir}`, `try_files` resolves the on-disk `apt/<dir>/...`).

---

## Task 1: APT engine — publish the full component set

**Files:**
- Modify: `engines/mirroret_apt.py` (`AptMirror.__init__`, `_fetch_suite_indices`, `main` argparse)
- Test: `tests/test_engines.bats`

**Interfaces:**
- Consumes: spec dict may carry `"all_components": true`.
- Produces: when `all_components` is set, the published index tree contains every component listed in the suite's signed `Release` `Components:` field, regardless of `spec["components"]`.

- [ ] **Step 1: Write the failing test** in `tests/test_engines.bats`: against a local fixture APT repo whose `Release` advertises `main universe`, run `mirroret_apt.py --spec` with a spec setting `components=["main"]` and `all_components=true`, `metadata_only=true`; assert the published `dists/<suite>/universe/binary-amd64/Packages` exists. Add a sibling test with `all_components` absent asserting `universe/...` is **not** published.
- [ ] **Step 2: Run to verify it fails** — Run: `bats tests/test_engines.bats -f all_components`. Expected: FAIL (universe not published).
- [ ] **Step 3: Implement.** In `AptMirror.__init__` read `self.all_components = bool(getattr(args, "all_components", False) or spec.get("all_components"))`. In `_fetch_suite_indices`, after `release = ReleaseIndex(release_text)` and the `if not release.entries` guard, add: `if self.all_components and release.components: self.components = list(release.components)`. Add argparse `--all-components` (store_true) in `main`. The existing `_entry_matches_filters` then keeps all components because `self.components` now equals the suite's full set.
- [ ] **Step 4: Run to verify it passes** — Run: `bats tests/test_engines.bats -f all_components`. Expected: PASS.
- [ ] **Step 5: Commit** — `git commit -m "feat(apt-engine): --all-components publishes the full signed component set"`

## Task 2: APT spec writer sets `all_components` in hybrid/cache

**Files:**
- Modify: `lib/targets.sh` (`write_apt_target_spec`, around line 486-503)
- Test: `tests/test_targets.bats`

**Interfaces:**
- Consumes: `MIRRORET_APT_MODE`.
- Produces: generated APT spec JSON contains `"all_components": true` iff `MIRRORET_APT_MODE` is `hybrid` or `cache`.

- [ ] **Step 1: Write the failing test** in `tests/test_targets.bats`: with `MIRRORET_APT_MODE=hybrid`, `write_apt_target_spec ubuntu noble amd64` output piped to `python3 -c 'import json,sys;print(json.load(sys.stdin)["all_components"])'` prints `True`; with `MIRRORET_APT_MODE=mirror` it prints `False`.
- [ ] **Step 2: Run to verify it fails** — Run: `bats tests/test_targets.bats -f all_components`. Expected: FAIL (`KeyError: all_components`).
- [ ] **Step 3: Implement.** Add a line next to the existing `metadata_only` line (`lib/targets.sh:501`): `"all_components": $(_json_bool "$([[ "${MIRRORET_APT_MODE:-mirror}" == "hybrid" || "${MIRRORET_APT_MODE:-mirror}" == "cache" ]] && echo 1 || echo 0)"),`
- [ ] **Step 4: Run to verify it passes** — Run: `bats tests/test_targets.bats -f all_components`. Expected: PASS.
- [ ] **Step 5: Commit** — `git commit -m "feat(targets): set all_components for hybrid/cache APT specs"`

## Task 3: APT client config advertises the full component set in hybrid/cache

**Files:**
- Modify: `lib/apt.sh` (`generate_apt_client_config` around line 552-566; add a manifest reader helper)
- Test: `tests/test_client_path.bats`

**Interfaces:**
- Consumes: the engine's published manifest `${MIRRORET_BASE_DIR}/apt/<dir>/dists/<codename>/.mirroret-manifest.json` with a `"components"` array (`engines/mirroret_apt.py:785-795`).
- Produces: in hybrid/cache the client `.sources`/`.list` Components field lists every component in the manifest; in mirror mode it keeps `_apt_components`/`MIRRORET_APT_COMPONENTS` behaviour.

- [ ] **Step 1: Write the failing test** in `tests/test_client_path.bats`: seed a fake manifest with `"components": ["main","universe"]`; with `MIRRORET_APT_MODE=hybrid`, `generate_apt_client_config` output contains `main universe` on the `deb ... ${codename} ...` line. A second test: `MIRRORET_APT_MODE=mirror` with `MIRRORET_APT_COMPONENTS=main` yields `main` only (manifest ignored).
- [ ] **Step 2: Run to verify it fails** — Run: `bats tests/test_client_path.bats -f client_components`. Expected: FAIL.
- [ ] **Step 3: Implement.** Add `_apt_manifest_components <dir> <codename>`: if the manifest file exists, `python3 -c` to print its `components` space-joined; else print empty. In `generate_apt_client_config`, when `MIRRORET_APT_MODE` is hybrid/cache and the manifest yields a non-empty list, use it for `components`; otherwise fall back to the current `_apt_components`/`MIRRORET_APT_COMPONENTS` value. Do not change the insecure/resign/signed-by branches' structure, only the `components` value they interpolate.
- [ ] **Step 4: Run to verify it passes** — Run: `bats tests/test_client_path.bats -f client_components`. Expected: PASS.
- [ ] **Step 5: Commit** — `git commit -m "feat(apt-client): widen client components to the published set in hybrid/cache"`

## Task 4: nginx routes APT `dists/` through the daemon in hybrid too

**Files:**
- Modify: `lib/nginx.sh` (`_nginx_apt_locations`, the `MIRRORET_APT_MODE == "cache"` gate at ~line 223)
- Test: `tests/test_cache_wiring.bats`

**Interfaces:**
- Consumes: `cache_mode_enabled`, `MIRRORET_APT_MODE`.
- Produces: emitted nginx config has a `location ~ ^/<dir>/dists/` daemon-proxy block whenever mode is `hybrid` **or** `cache` (not cache-only).

- [ ] **Step 1: Write the failing test** in `tests/test_cache_wiring.bats`: with `MIRRORET_APT_MODE=hybrid`, the generated vhost contains `location ~ ^/ubuntu/dists/`; with `MIRRORET_APT_MODE=mirror` it does not.
- [ ] **Step 2: Run to verify it fails** — Run: `bats tests/test_cache_wiring.bats -f hybrid_dists`. Expected: FAIL (regex location only emitted for cache).
- [ ] **Step 3: Implement.** Change the condition gating the `location ~ ^/%s/dists/` block (`lib/nginx.sh:223`) from `"${MIRRORET_APT_MODE:-}" == "cache"` to: on_demand is 1 AND mode is `cache` OR `hybrid`. Leave the pool/`try_files` prefix location as-is (it already fires for any on-demand mode).
- [ ] **Step 4: Run to verify it passes** — Run: `bats tests/test_cache_wiring.bats -f hybrid_dists`. Expected: PASS.
- [ ] **Step 5: Commit** — `git commit -m "fix(nginx): revalidate APT dists/ through the daemon in hybrid mode"`

## Task 5: RPM engine — `--metadata-only`

**Files:**
- Modify: `engines/mirroret_rpm.py` (the mirror class `__init__`/filter logic around `self.filtered` at line 821, the publish path at 657-667, the download step, `main` argparse)
- Test: `tests/test_engines.bats`

**Interfaces:**
- Consumes: spec `"metadata_only": true` or `--metadata-only`.
- Produces: in metadata-only mode the published `repodata/` is upstream's verbatim `repomd.xml` (+ `repomd.xml.asc` **iff upstream had one**) listing the full package set, and **no** `.rpm` payloads are downloaded.

- [ ] **Step 1: Write the failing test** in `tests/test_engines.bats`: against a local fixture RPM repo with 2 packages and a signed `repomd.xml.asc`, run `mirroret_rpm.py --spec` with `metadata_only=true`; assert (a) `repodata/repomd.xml.asc` is published, (b) the published `primary` lists both packages, (c) no `*.rpm` exists under the dest. Add a second fixture with no `.asc`: assert `repomd.xml` published, no `.asc`, still no `.rpm`.
- [ ] **Step 2: Run to verify it fails** — Run: `bats tests/test_engines.bats -f rpm_metadata_only`. Expected: FAIL (`--metadata-only` unknown / packages downloaded).
- [ ] **Step 3: Implement.** Add argparse `--metadata-only` and read `self.metadata_only` from args/spec. When set: force `self.filtered = False` (so the verbatim `repomd_raw`/`asc` publish path at 657-667 is taken), fetch all referenced metadata as today, publish `repomd.xml` + (only if fetched) `repomd.xml.asc` verbatim, and skip the `.rpm` download loop (the equivalent of APT's `self.wanted = {}` / no-download branch). Do not prune packages in metadata-only mode (same reasoning as APT `prune skipped: metadata-only`).
- [ ] **Step 4: Run to verify it passes** — Run: `bats tests/test_engines.bats -f rpm_metadata_only`. Expected: PASS.
- [ ] **Step 5: Commit** — `git commit -m "feat(rpm-engine): --metadata-only publishes verbatim signed repodata, no packages"`

## Task 6: `MIRRORET_RPM_MODE`, native-engine requirement, RPM spec `metadata_only`

**Files:**
- Modify: `lib/cache.sh` (new `validate_rpm_mode`, `rpm_cache_mode_enabled`, `rpm_mode_is_metadata_only`), `lib/rpm.sh` (`_rpm_resolve_engine` guard), `lib/targets.sh` (`write_rpm_target_spec` adds `metadata_only`)
- Test: `tests/test_cache.bats`, `tests/test_rhel.bats`

**Interfaces:**
- Consumes: `MIRRORET_RPM_MODE` (default `mirror`).
- Produces: `rpm_cache_mode_enabled` (true for hybrid/cache); RPM spec JSON carries `"metadata_only": true` in hybrid/cache; selecting reposync while RPM mode is hybrid/cache dies with a clear message.

- [ ] **Step 1: Write the failing tests.** `tests/test_cache.bats`: `MIRRORET_RPM_MODE=hybrid` → `rpm_cache_mode_enabled` returns 0; `=mirror` → returns 1 (false). `tests/test_rhel.bats`: with `MIRRORET_RPM_MODE=hybrid` and an engine resolution that would pick reposync, the call dies with a message containing `requires the native engine`.
- [ ] **Step 2: Run to verify they fail** — Run: `bats tests/test_cache.bats -f rpm_mode; bats tests/test_rhel.bats -f rpm_hybrid_native`. Expected: FAIL.
- [ ] **Step 3: Implement.** In `lib/cache.sh` add `MIRRORET_RPM_MODE="${MIRRORET_RPM_MODE:-mirror}"`, `validate_rpm_mode` (mirror|hybrid|cache else die), `rpm_cache_mode_enabled` (hybrid|cache → 0), `rpm_mode_is_metadata_only` (hybrid|cache → 0; both metadata-only, since RPM has no "mirror indices + fetch pool up front" middle state — hybrid and cache differ only in whether a nightly warm runs). In `lib/rpm.sh` `_rpm_resolve_engine`, if `rpm_cache_mode_enabled` and the resolution is not native, `die` with "MIRRORET_RPM_MODE=... requires the native engine (reposync has no metadata-only mode)". In `lib/targets.sh` `write_rpm_target_spec`, add `"metadata_only": $(_json_bool "$(rpm_mode_is_metadata_only && echo 1 || echo 0)"),`.
- [ ] **Step 4: Run to verify they pass** — Run: `bats tests/test_cache.bats -f rpm_mode; bats tests/test_rhel.bats -f rpm_hybrid_native`. Expected: PASS.
- [ ] **Step 5: Commit** — `git commit -m "feat(rpm): MIRRORET_RPM_MODE with native-engine requirement for hybrid/cache"`

## Task 7: cache route table includes RPM; daemon cache-dir at `${base_dir}`

**Files:**
- Modify: `lib/cache.sh` (`generate_cache_config` emits APT routes keyed `apt/<dir>` and RPM routes keyed `redhat/mirror/<flavor>/<major>/<repo>`; `install_cache_service` launcher `--cache-dir ${base_dir}`), and gate daemon on `cache_mode_enabled || rpm_cache_mode_enabled`
- Test: `tests/test_cache.bats`, `tests/test_cache_wiring.bats`

**Interfaces:**
- Consumes: resolved APT and RPM targets; `apt_suites`, the RPM repo→upstream table used by `write_rpm_target_spec`.
- Produces: `cache.json` whose `routes` keys are the on-disk/client-tree prefixes (`apt/ubuntu`, `redhat/mirror/ol/9/baseos`), each with `kind` and `upstreams`; daemon launched with `--cache-dir ${base_dir}`.

- [ ] **Step 1: Write the failing test** in `tests/test_cache.bats`: with an APT target `ubuntu:noble` and RPM target `ol:9` in hybrid, `generate_cache_config` writes a JSON whose `routes` contains keys `apt/ubuntu` and `redhat/mirror/ol/9/baseos` (kind `rpm`, upstream matching the oracle base). Assert the launcher written by `install_cache_service` contains `--cache-dir` with the base dir and not `/apt`.
- [ ] **Step 2: Run to verify it fails** — Run: `bats tests/test_cache.bats -f rpm_routes`. Expected: FAIL (only `ubuntu` key, cache-dir ends in `/apt`).
- [ ] **Step 3: Implement.** Change APT route keying to `apt/<dir>`. Add an RPM pass: for each resolved RPM target, enumerate its repos and upstreams (reuse the same table `write_rpm_target_spec` uses) and emit one route per repo keyed on the client-tree prefix `redhat/mirror/<flavor>/<major>/<repo>` with `"kind":"rpm"`. Change the launcher's `--cache-dir "${base_dir}/apt"` to `--cache-dir "${base_dir}"`. Update `configure_cache` / daemon-needed gate to `cache_mode_enabled || rpm_cache_mode_enabled`.
- [ ] **Step 4: Run to verify it passes** — Run: `bats tests/test_cache.bats -f rpm_routes`. Expected: PASS.
- [ ] **Step 5: Commit** — `git commit -m "feat(cache): RPM routes and base-dir-rooted cache daemon"`

## Task 8: daemon longest-prefix `resolve()` + base-dir root

**Files:**
- Modify: `engines/mirroret_cache.py` (`Cache.resolve`, and any `route.name`-based disk join)
- Test: `tests/test_cache.bats` (python unit via `python3 -c`) or a new `tests/test_cache_resolve.bats`

**Interfaces:**
- Consumes: routes whose names are multi-segment prefixes (`apt/ubuntu`, `redhat/mirror/ol/9/baseos`); `--cache-dir ${base_dir}`.
- Produces: `resolve(path)` returns `(route, rel, disk)` by matching the **longest** route-name prefix of the cleaned path; `rel` is the remainder after that prefix; `disk = ${cache_dir}/${route.name}/${rel}`. Traversal rejection unchanged.

- [ ] **Step 1: Write the failing test**: load a `Cache` with routes `apt/ubuntu` and `redhat/mirror/ol/9/baseos`; assert `resolve('/redhat/mirror/ol/9/baseos/repodata/repomd.xml')` picks route `redhat/mirror/ol/9/baseos` and rel `repodata/repomd.xml`; assert `resolve('/apt/ubuntu/pool/main/x.deb')` picks `apt/ubuntu`, rel `pool/main/x.deb`; assert a path matching no route returns `None`; assert `../` traversal returns `None`.
- [ ] **Step 2: Run to verify it fails** — Run: `bats tests/test_cache*.bats -f resolve_prefix`. Expected: FAIL (single-segment matcher can't find the RPM route).
- [ ] **Step 3: Implement.** Replace the first-segment lookup (`mirroret_cache.py:323-327`) with: clean the path as today, then select the route whose `name` is the longest prefix such that `clean == name` or `clean.startswith(name + "/")`; `rel = clean[len(name):].lstrip("/")`. Keep every existing guard (empty/trailing-slash/NUL reject, `.`/`..` segment reject, `disk.startswith(root + os.sep)`, directory/ancestor-is-file checks), with `root = os.path.join(self.cache_dir, route.name)`. Routes must be iterated longest-name-first.
- [ ] **Step 4: Run to verify it passes** — Run: `bats tests/test_cache*.bats -f resolve_prefix`. Expected: PASS. Then run the full `tests/test_cache.bats tests/test_cache_wiring.bats` to confirm APT still resolves under the new `apt/<dir>` keys.
- [ ] **Step 5: Commit** — `git commit -m "feat(cache-daemon): longest-prefix route resolution, base-dir rooted"`

## Task 9: nginx RPM pull-through wiring

**Files:**
- Modify: `lib/nginx.sh` (RPM `/redhat/` location at ~line 83; add per-mode `try_files @mirroret_cache` and a `repodata/` daemon route)
- Test: `tests/test_cache_wiring.bats`

**Interfaces:**
- Consumes: `rpm_cache_mode_enabled`, the cache-miss handler `@mirroret_cache` (already emitted when any on-demand mode is on).
- Produces: when RPM mode is hybrid/cache, RPM tree uses `root ${base_dir};` + `try_files $uri @mirroret_cache;`, and a `location ~ ^/redhat/mirror/.*/repodata/` daemon block for TTL revalidation; in mirror mode the current `alias ... autoindex` is unchanged.

- [ ] **Step 1: Write the failing test** in `tests/test_cache_wiring.bats`: with `MIRRORET_RPM_MODE=hybrid`, the vhost contains `try_files $uri @mirroret_cache` under a `/redhat/` location and a `location ~ ^/redhat/mirror/.*/repodata/`; with `MIRRORET_RPM_MODE=mirror` it keeps `alias` and has neither.
- [ ] **Step 2: Run to verify it fails** — Run: `bats tests/test_cache_wiring.bats -f rpm_pullthrough`. Expected: FAIL.
- [ ] **Step 3: Implement.** Make the RPM location emission mode-aware mirroring the APT pattern in `_nginx_apt_locations`: in hybrid/cache emit `root ${base_dir};` + `try_files $uri @mirroret_cache;` for `/redhat/` and a regex `repodata/` daemon block; ensure the shared `@mirroret_cache` handler is emitted when `cache_mode_enabled || rpm_cache_mode_enabled`. Keep the miss-handler body (`_nginx_cache_proxy_directives`) shared.
- [ ] **Step 4: Run to verify it passes** — Run: `bats tests/test_cache_wiring.bats -f rpm_pullthrough`. Expected: PASS.
- [ ] **Step 5: Commit** — `git commit -m "feat(nginx): RPM pull-through and repodata revalidation wiring"`

## Task 10: RPM client `.repo` emits `repo_gpgcheck=1` in metadata-only mode

**Files:**
- Modify: `lib/rpm.sh` (`generate_rpm_client_config`, around line 495-552)
- Test: `tests/test_rhel.bats`

**Interfaces:**
- Consumes: `rpm_mode_is_metadata_only`; the published `repodata/repomd.xml.asc` presence.
- Produces: `.repo` contains `repo_gpgcheck=1` iff RPM mode is metadata-only AND an `.asc` is published for that repo; otherwise `repo_gpgcheck` stays omitted (current behaviour). `gpgcheck=1` line unchanged in all non-insecure modes.

- [ ] **Step 1: Write the failing test** in `tests/test_rhel.bats`: with `MIRRORET_RPM_MODE=hybrid` and a published `repomd.xml.asc` present for the repo, `generate_rpm_client_config` output contains `repo_gpgcheck=1`; with `MIRRORET_RPM_MODE=mirror` (filtered) it contains no `repo_gpgcheck` line; with hybrid but no `.asc` present, no `repo_gpgcheck` line.
- [ ] **Step 2: Run to verify it fails** — Run: `bats tests/test_rhel.bats -f repo_gpgcheck`. Expected: FAIL.
- [ ] **Step 3: Implement.** In `generate_rpm_client_config`, after the existing `gpg_check_line` logic, add a `repo_gpgcheck` line to the emitted `.repo` body only when `rpm_mode_is_metadata_only` is true AND the repo's published `repodata/repomd.xml.asc` exists. Do not add it in insecure mode. Keep the existing `gpgcheck`/`gpgkey` lines exactly.
- [ ] **Step 4: Run to verify it passes** — Run: `bats tests/test_rhel.bats -f repo_gpgcheck`. Expected: PASS.
- [ ] **Step 5: Commit** — `git commit -m "feat(rpm-client): repo_gpgcheck=1 in metadata-only mode when signed repodata is served"`

## Task 11: Full-suite regression + docs

**Files:**
- Modify: `docs/CACHE.md`, `docs/MULTI-DISTRO.md`, `README.md` (storage-mode + RPM mode), `config/mirroret.conf.example` (`MIRRORET_RPM_MODE`)
- Test: entire `tests/` suite

- [ ] **Step 1:** Run `make lint` and `make test`. Expected: all green. Fix any regression a prior task introduced in the shared nginx/cache/targets code.
- [ ] **Step 2:** Document `MIRRORET_RPM_MODE`, APT full-component hybrid behaviour, and RPM pull-through in the four files above. Add `#MIRRORET_RPM_MODE=mirror` with a comment to `config/mirroret.conf.example`.
- [ ] **Step 3: Commit** — `git commit -m "docs: hybrid completeness, RPM mode and pull-through"`

---

## Self-Review

**Spec coverage:** §1a → Tasks 1–3; §1b → Task 4; §1c → Tasks 5, 6, 10; §1d → Tasks 7, 8, 9; acceptance criteria → Tasks 1/3 (universe install), 5/9 (RPM pull-through), 4 (freshness), 8 (longest-prefix), 10 (repo_gpgcheck), 11 (regression). Covered.

**Review Focus:** each of the five lines maps to a task test (3, 5/10, 8, 6, 8/4). Covered.

**Type/name consistency:** `rpm_cache_mode_enabled`, `rpm_mode_is_metadata_only`, `validate_rpm_mode` defined in Task 6, consumed in 7/9/10; `all_components` spec key defined Task 1, set Task 2; manifest `components` consumed Task 3 from the key the engine already writes; route keys `apt/<dir>` / `redhat/mirror/<flavor>/<major>/<repo>` defined Task 7, consumed Task 8/9. Consistent.

**Proportion:** plan is tasks+tests+signatures, no full function bodies. In proportion to the spec.
