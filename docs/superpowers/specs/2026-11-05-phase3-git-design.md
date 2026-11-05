# Phase 3 — Git pull-through mirror

Design document. Status: **approved** (owner authorized continuous execution:
"merge to main, do not stop"). Builds on the parent design's §Phase 3.

## Intent

Clients `git clone http://SERVER/git/<host>/<path>` and get a public upstream
repo from the LAN mirror — fast, and usable when the client has no direct
internet. The owner chose "mirror upstream repos, fetch on miss, cache,"
server always online.

## Approach: dumb-HTTP bare mirrors

A read-only clone works over plain HTTP against a bare repo that has had
`git update-server-info` run (dumb protocol). So the mirror needs **no**
`git-http-backend`/`fcgiwrap`: nginx serves the bare-repo tree as static
files, exactly as it serves APT/RPM. The store is
`${MIRRORET_BASE_DIR}/git/<host>/<path>.git` bare mirrors.

Two ways a repo gets into the store:
- **Pre-seed + scheduled update** (the reliable core): `mirroretctl git add
  <host>/<path>` clones it now; a nightly job runs `git remote update` +
  `git update-server-info` on every mirror. Fully offline-capable for
  clients once seeded.
- **On-miss pull-through** (matches the chosen model): a request for a repo
  not yet in the store is handed by nginx to the `mirroret-cache` daemon,
  which clones `--mirror` from the upstream, runs `update-server-info`, and
  then serves the requested dumb-HTTP file off disk. The daemon already owns
  the "serve a tree, fill misses from upstream" role; git is a new route
  kind whose "fetch" is a `git clone`/`remote update` instead of an HTTP GET.

## Goals
- `git clone http://SERVER/git/github.com/<org>/<repo>` works for a seeded
  repo with the server offline-to-client.
- `mirroretctl git add github.com/<org>/<repo>` clones it into the store.
- A nightly job refreshes every mirror (`remote update` + `update-server-info`).
- On-miss: a clone of an un-seeded public repo triggers a one-time
  `clone --mirror` via the daemon, then serves it.
- Every upstream host/path is validated before it reaches a `git` CLI call
  or a shell command (no argument/again injection).

## Non-goals
- Smart-HTTP (`git-http-backend`), push, auth, private repos. Read-only
  dumb-HTTP clone of public repos only.
- Mirroring non-git VCS.
- Rewriting the cache daemon; git is an added route kind.

## Anti-goals
- A clone path that passes an attacker-influenced string to `git` as a flag
  or shell (`--upload-pack=…`, `;`, `$(...)`). Host and path are validated
  to a strict charset and the upstream URL is always `https://<host>/<path>`.
- Serving a partially-cloned repo (a clone interrupted mid-fetch must not be
  served as if complete).

## Decisions (builder/owner calls)
- **Store layout:** `${base}/git/<host>/<path>.git`, bare `--mirror`.
  Client URL `/git/<host>/<path>` maps to it; nginx strips nothing
  (`alias ${base}/git/`), so `/git/github.com/o/r/info/refs` →
  `${base}/git/github.com/o/r.git/info/refs`? No — the client clones
  `/git/<host>/<path>` and git appends `/info/refs` etc. The store dir must
  therefore be `<host>/<path>` (the `.git` suffix is NOT in the client URL).
  Decision: store at `${base}/git/<host>/<path>` as a bare repo (no `.git`
  suffix in the path), so the client URL maps 1:1 to disk and nginx is a
  plain `alias`. `git clone --mirror <upstream> <dir>` into that dir.
- **Upstream URL:** always `https://<host>/<path>`. `<host>` matches
  `^[A-Za-z0-9.-]+$`; each `<path>` segment matches `^[A-Za-z0-9._-]+$`
  (no `..`, no leading `-`). A trailing `.git` on the client path is
  accepted and normalised.
- **Validation helper** `_git_valid_repo <host> <path>` rejects anything
  else; used by `git add`, the sync script, and the daemon.
- **Allowed upstream hosts:** `MIRRORET_GIT_ALLOWED_HOSTS` (space list,
  default `github.com gitlab.com bitbucket.org codeberg.org
  git.sr.ht`). On-miss only clones from an allowed host; `git add` warns but
  permits an off-list host (operator is explicit).
- **nginx:** `location /git/ { alias ${base}/git/; autoindex on; }` always;
  plus, when on-miss is enabled, `try_files $uri @git_miss` and an
  `@git_miss` → daemon. Static `alias` means a seeded clone is served with
  zero daemon involvement.
- **Daemon git route:** route `kind: "git"` whose `root` is `${base}/git`
  and whose "fetch" ensures the mirror (`clone --mirror` if absent, nothing
  if present — freshness is the nightly job's job, not per-request) then
  serves the requested file off disk. The repo dir is the longest path
  prefix of the request that is (or becomes) a git mirror; the remainder is
  the dumb-HTTP file.
- **Freshness:** mirrors refresh on the nightly `sync-all` (new
  `sync-git-repos.sh`), not per request. A clone served from a mirror up to
  24 h stale is acceptable for the LAN-cache use; documented.

## What is left to the builder
- Exact nginx precedence so `/git/.../info/refs` is served by the alias when
  present and only falls to `@git_miss` on a real miss (`try_files`).
- How the daemon detects "this path is a git repo root": probe for `HEAD` +
  `objects/` under successive path prefixes; cap the depth.
- Where `sync-git-repos.sh` enumerates mirrors (walk `${base}/git` for dirs
  containing `HEAD`).
- Test coverage: path/URL mapping + validation (reject `..`, `;`, `$(`,
  leading `-`); an end-to-end dumb-HTTP clone from a seeded local fixture
  bare repo served by `python -m http.server` (no nginx needed); the sync
  script refreshes a mirror; `mirroretctl git add` validates + clones from a
  `file://` or local fixture upstream.

## Acceptance
- `_git_valid_repo github.com org/repo` true; `_git_valid_repo 'h' '../x'`,
  `';'`, `'$(x)'`, `-/r` false.
- `_git_mirror_url github.com org/repo` = `https://github.com/org/repo`.
- Clone of a seeded fixture bare repo over dumb HTTP returns its commits.
- `sync-git-repos.sh` on a seeded mirror runs `remote update` +
  `update-server-info` and leaves a cloneable repo.
- `mirroretctl git add <host>/<path>` (fixture upstream) creates a cloneable
  mirror; `mirroretctl git add 'evil$(x)/r'` is refused.
- 0 new test failures vs base.
