# Phase 2: Docker secure/seedable Implementation Plan

> REQUIRED SUB-SKILL: superpowers:executing-plans (inline, TDD per task).

**Goal:** Docker registry reachable only via nginx `/v2/` (loopback bind), image list cannot inject shell, and `mirroretctl docker add` seeds images.

**Spec:** `docs/superpowers/specs/2026-11-05-phase2-docker-design.md`

## Global Constraints
- Backward-compatible: `MIRRORET_DOCKER_BIND=all` restores `0.0.0.0` + opens the port.
- No real Docker in tests; assert generated config/scripts (BATS), as the suite does.
- Keep the `mirroret-managed` marker / `--upgrade` contract.

## Review Focus
- An image containing a shell metacharacter (`;`, `$(`, backtick, space, newline) must never reach the generated script unquoted — Task 1.
- `MIRRORET_DOCKER_BIND=all` must reopen BOTH the registry addr and the firewall port, or clients break — Tasks 2,3.
- Client config must not advertise a port the registry no longer listens on — Task 4.

## Task 1: image validation + injection fix
**Files:** `lib/docker_registry.sh` (`_docker_valid_image` new; image-list loop ~565), test `tests/test_docker.bats` (new).
- [ ] Test: generating the sync script from an images file containing `ubuntu:22.04`, `$(touch /tmp/pwn)`, `a;b`, `nginx:stable` yields a script whose IMAGES array contains `ubuntu:22.04` and `nginx:stable` and NOT `touch` or `;b`.
- [ ] Run → FAIL.
- [ ] Implement `_docker_valid_image <s>`: returns 0 iff `[[ "$s" =~ ^[A-Za-z0-9][A-Za-z0-9._/:@-]*$ ]]`. In the image-list loop, `_docker_valid_image "${line}" || { warn "skipping invalid image: ${line}"; continue; }`.
- [ ] Run → PASS. Commit.

## Task 2: registry binds loopback
**Files:** `lib/docker_registry.sh` (`_emit_registry_config` addr ~246; container `-p` ~354), test `tests/test_docker.bats`.
- [ ] Test: default → config `http.addr` is `127.0.0.1:${port}` and container run has `-p 127.0.0.1:${port}:${port}`; with `MIRRORET_DOCKER_BIND=all` → `addr: :${port}` and `-p ${port}:${port}`.
- [ ] Run → FAIL.
- [ ] Implement: `_docker_bind_addr` prints `127.0.0.1:${port}` by default, `:${port}` when `MIRRORET_DOCKER_BIND=all`; use it in both the config `addr:` and the `-p`.
- [ ] Run → PASS. Commit.

## Task 3: firewall excludes the registry port by default
**Files:** `lib/firewall.sh` (`list_required_ports`), the installer's docker-port opening site (grep `DOCKER_REGISTRY_PORT` in `install.sh`), test `tests/test_docker.bats` or `tests/test_cli.bats`.
- [ ] Test: with default bind, `list_required_ports` output does NOT contain the registry port line; with `MIRRORET_DOCKER_BIND=all` it does.
- [ ] Run → FAIL.
- [ ] Implement: gate the registry-port entry in `list_required_ports` (and the installer's opened-ports set) on `[[ "${MIRRORET_DOCKER_BIND:-loopback}" == "all" ]]`.
- [ ] Run → PASS. Commit.

## Task 4: client daemon.json uses the nginx endpoint
**Files:** `lib/docker_registry.sh` (`generate_docker_client_config` ~449-532), test `tests/test_docker.bats`.
- [ ] Test: default (loopback, no TLS) → daemon.json references `${MIRRORET_SERVER_IP}:${MIRRORET_WEB_PORT}` and does NOT contain `:${MIRRORET_DOCKER_REGISTRY_PORT}`; with `MIRRORET_DOCKER_BIND=all` → references the registry port as today.
- [ ] Run → FAIL.
- [ ] Implement: compute `registry_host_port` as the nginx endpoint (`${server}:${web_port}`) in the default bind mode, keep the raw registry port only under `MIRRORET_DOCKER_BIND=all`. TLS path uses the existing nginx TLS URL (unchanged). Keep `registry-mirrors`/`insecure-registries`/hosted branches intact, only the host:port value changes.
- [ ] Run → PASS. Commit.

## Task 5: `mirroretctl docker add`
**Files:** `mirroretctl` (dispatch + `cmd_docker_add`), test `tests/test_cli.bats`.
- [ ] Test: `mirroretctl docker add ubuntu:22.04` (with MIRRORET_DOCKER_IMAGES_FILE pointed at a temp file) appends `ubuntu:22.04` once (idempotent on a second call); `mirroretctl docker add 'evil$(x)'` exits non-zero and writes nothing.
- [ ] Run → FAIL.
- [ ] Implement: `cmd_docker_add <image>` validates with the same regex as `_docker_valid_image` (duplicate the pattern in `mirroretctl`, which does not source lib/), ensures the images file exists, appends if absent, prints the seed hint. Wire `docker add` into the subcommand dispatch and `help`.
- [ ] Run → PASS. Commit.

## Task 6: docs + regression
- [ ] `docs/CONFIGURATION.md` / README / config example: `MIRRORET_DOCKER_BIND`, the nginx-fronted access, `mirroretctl docker add`.
- [ ] Full suite: 0 new failures vs base. Commit.

## Self-Review
Coverage: injection (T1), exposure (T2+T3), client config (T4), seed UX (T5), docs (T6). Review Focus mapped to T1/T2-3/T4. Names consistent (`_docker_valid_image`, `_docker_bind_addr`, `MIRRORET_DOCKER_BIND`).
