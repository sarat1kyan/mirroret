# Phase 2 — Docker: secure, seedable, pull-through

Design document. Status: **approved** (owner authorized continuous execution
through all phases on 2026-11-05: "merge to main, do not stop"). Builds on
`2026-11-05-completeness-and-pullthrough-design.md` §Phase 2.

## Intent

The owner wants to "add images manually or pull them, and clients get those
images from the mirror server." Today the registry works but has two holes
from the audit: it binds `0.0.0.0:5000` with no auth, and the image list is
spliced into a generated root script with no validation (command injection).

Principle: clients reach Docker images through the **mirror's own HTTP
front** (nginx `/v2/`, already proxied), not a separate unauthenticated
port, and nothing an operator drops in an image list can execute as root.

## Goals

- The registry is not reachable unauthenticated on the LAN: it binds
  loopback and nginx `/v2/` is the only network path (same host:port
  clients already use for APT/RPM).
- Clients pull via the nginx endpoint; generated `daemon.json` points there.
- An image list cannot inject shell into the generated sync script.
- `mirroretctl docker add <image>` appends a validated image to the list and
  (hosted mode) seeds it.

## Non-goals

- htpasswd/basic-auth on the registry itself (loopback + nginx is the
  boundary this round; basic-auth can be layered later at nginx).
- Changing the cache vs hosted model, or the native/container backend choice.
- Running real Docker in tests (the box has none); tests assert the
  generated config/scripts, as the rest of the suite does.

## Anti-goals

- A client config that still lists `:5000` as an insecure-registry while the
  registry no longer listens there.
- Breaking an existing hosted-mode push workflow without a path forward.

## Decisions (builder/owner calls)

- **Registry binds `127.0.0.1:${MIRRORET_DOCKER_REGISTRY_PORT}`** (config
  `http.addr` and the container `-p 127.0.0.1:port:port`). nginx `/v2/`
  (`lib/nginx.sh:158`) already proxies to it, so LAN clients use the web
  port (8080, or 8443 TLS). Backward-compatible escape hatch
  `MIRRORET_DOCKER_BIND=all` restores `0.0.0.0` for anyone who truly needs
  the raw port.
- **Firewall no longer opens the registry port by default** (`lib/firewall.sh`
  `list_required_ports`, and the installer's opened set): the registry is
  loopback, fronted by nginx on the already-open web port. With
  `MIRRORET_DOCKER_BIND=all` the port is opened again.
- **Client `daemon.json` points at the nginx endpoint**
  (`http://SERVER:${web_port}` or the TLS URL), not `SERVER:5000`. In cache
  mode that is `registry-mirrors`; in hosted mode clients pull
  `SERVER:${web_port}/<image>`. `insecure-registries` lists the nginx
  host:port when TLS is off, not `:5000`.
- **Image-list validation:** one shared helper `_docker_valid_image`
  accepts only `^[A-Za-z0-9][A-Za-z0-9._/:@-]*$`. Invalid lines are dropped
  with a warning in `sync-docker-images.sh` generation and rejected by
  `mirroretctl docker add`. This closes the injection at
  `lib/docker_registry.sh:565-570`.
- **`mirroretctl docker add <image>`:** validate, append to
  `MIRRORET_DOCKER_IMAGES_FILE` (default `/etc/mirroret/docker-images.txt`),
  de-duplicate; print how to seed (`sudo mirroretctl sync docker`).

## What is left to the builder

- Exact nginx host:port the client config should use (reuse whatever the
  APT/RPM client configs already compute for the server address and web
  port; do not invent a new one).
- Whether `MIRRORET_DOCKER_IMAGES_FILE` default path needs creating on
  install (create empty with a comment header if absent).
- Test coverage in `tests/test_rhel.bats` / a docker-focused BATS file:
  injection line dropped, loopback addr emitted, `MIRRORET_DOCKER_BIND=all`
  restores `0.0.0.0`, client config no longer references `:5000`, firewall
  list excludes the registry port by default, `mirroretctl docker add`
  validates and appends.

## Acceptance

- Generated registry config `http.addr` is `127.0.0.1:5000` by default,
  `0.0.0.0:5000`-equivalent only with `MIRRORET_DOCKER_BIND=all`.
- Generated `sync-docker-images.sh` drops a line like `$(touch x)` or
  `a;b` and keeps `ubuntu:22.04`.
- `generate_docker_client_config` output contains the web-port nginx
  endpoint and does not reference the raw registry port in the default
  (loopback) mode.
- `list_required_ports` / installer opened set excludes the registry port
  unless `MIRRORET_DOCKER_BIND=all`.
- `mirroretctl docker add 'evil$(x)'` is refused; `mirroretctl docker add
  ubuntu:22.04` appends once.
- Existing non-docker suites stay green; 0 new failures vs base.
