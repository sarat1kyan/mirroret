#!/usr/bin/env bats
# Git pull-through mirror: validation, mapping, fetch/serve, sync.

load 'test_helpers'

setup() {
    load_lib
    source "${SCRIPT_DIR}/lib/git.sh"
    TMPDIR_TEST="$(mktemp -d)"
    MIRRORET_BASE_DIR="${TMPDIR_TEST}/srv"
    mkdir -p "${MIRRORET_BASE_DIR}"
    no_proxy_env 2>/dev/null || true
    export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
    export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
}

teardown() {
    [[ -n "${TMPDIR_TEST:-}" ]] && rm -rf "${TMPDIR_TEST}"
}

@test "git: valid repo refs are accepted" {
    _git_valid_repo github.com "org/repo"
    _git_valid_repo gitlab.com "group/sub/proj"
    _git_valid_repo github.com "org/repo.git"
}

@test "git: a traversal path is rejected" {
    ! _git_valid_repo github.com "../etc"
}

@test "git: a shell-metachar path is rejected" {
    ! _git_valid_repo github.com 'a;b'
    ! _git_valid_repo github.com 'x$(touch y)'
}

@test "git: a leading-dash host or segment is rejected (flag injection)" {
    ! _git_valid_repo "-h" "r/r"
    ! _git_valid_repo github.com "-leading/r"
}

@test "git: upstream url is https host/path" {
    run _git_mirror_url github.com "org/repo"
    [ "$output" = "https://github.com/org/repo" ]
}

@test "git: store dir maps 1:1 to the client path, .git normalised off" {
    run _git_store_dir "/srv" github.com "org/repo.git"
    [ "$output" = "/srv/git/github.com/org/repo" ]
}

# _mk_source_repo <dir> - a tiny real repo with one commit on branch main.
_mk_source_repo() {
    local d="$1"
    git init -q -b main "$d"
    ( cd "$d" && echo hello > file.txt && git add file.txt && git commit -q -m init )
}

@test "git: ensure_mirror clones a bare mirror that is cloneable" {
    local src="${TMPDIR_TEST}/src"
    _mk_source_repo "${src}"
    # Clone from the local path (upstream override).
    MIRRORET_GIT_UPSTREAM_OVERRIDE="file://${src}"
    run _git_ensure_mirror "${MIRRORET_BASE_DIR}" example.com "o/r"
    [ "$status" -eq 0 ]
    local store="${MIRRORET_BASE_DIR}/git/example.com/o/r"
    [ -f "${store}/HEAD" ]
    [ -f "${store}/info/refs" ]
    # A client can clone it.
    git clone -q "${store}" "${TMPDIR_TEST}/clone"
    [ -f "${TMPDIR_TEST}/clone/file.txt" ]
}

@test "git: update_mirror brings across a new upstream commit" {
    local src="${TMPDIR_TEST}/src"
    _mk_source_repo "${src}"
    MIRRORET_GIT_UPSTREAM_OVERRIDE="file://${src}"
    _git_ensure_mirror "${MIRRORET_BASE_DIR}" example.com "o/r"
    ( cd "${src}" && echo more >> file.txt && git commit -qam second )
    run _git_update_mirror "${MIRRORET_BASE_DIR}/git/example.com/o/r"
    [ "$status" -eq 0 ]
    git clone -q "${MIRRORET_BASE_DIR}/git/example.com/o/r" "${TMPDIR_TEST}/clone"
    [ "$(wc -l < "${TMPDIR_TEST}/clone/file.txt")" -eq 2 ]
}

@test "git: an interrupted clone is not left as a complete-looking mirror" {
    # A pre-existing empty store dir (a crashed previous clone) must not be
    # treated as a valid mirror; ensure_mirror repairs it.
    local src="${TMPDIR_TEST}/src"
    _mk_source_repo "${src}"
    local store="${MIRRORET_BASE_DIR}/git/example.com/o/r"
    mkdir -p "${store}"   # empty, no HEAD
    MIRRORET_GIT_UPSTREAM_OVERRIDE="file://${src}"
    run _git_ensure_mirror "${MIRRORET_BASE_DIR}" example.com "o/r"
    [ "$status" -eq 0 ]
    [ -f "${store}/HEAD" ]
}

@test "git: generated sync script is valid and refreshes every mirror" {
    local src="${TMPDIR_TEST}/src"
    _mk_source_repo "${src}"
    MIRRORET_GIT_UPSTREAM_OVERRIDE="file://${src}"
    _git_ensure_mirror "${MIRRORET_BASE_DIR}" example.com "o/r"

    DRY_RUN=0 write_git_sync_script "${MIRRORET_BASE_DIR}/scripts/sync-git-repos.sh"
    bash -n "${MIRRORET_BASE_DIR}/scripts/sync-git-repos.sh"
    grep -q 'update-server-info' "${MIRRORET_BASE_DIR}/scripts/sync-git-repos.sh"

    # New upstream commit, then run the generated script: it must come across.
    ( cd "${src}" && echo more >> file.txt && git commit -qam second )
    bash "${MIRRORET_BASE_DIR}/scripts/sync-git-repos.sh" >/dev/null 2>&1
    git clone -q "${MIRRORET_BASE_DIR}/git/example.com/o/r" "${TMPDIR_TEST}/clone"
    [ "$(wc -l < "${TMPDIR_TEST}/clone/file.txt")" -eq 2 ]
}

@test "git: nginx serves /git as a static alias when enabled" {
    source "${SCRIPT_DIR}/lib/nginx.sh"
    MIRRORET_ENABLE_GIT=1
    run _nginx_git_location /srv/mirroret
    [ "$status" -eq 0 ]
    [[ "$output" == *"location /git/"* ]]
    [[ "$output" == *"alias /srv/mirroret/git/"* ]]
}

@test "git: nginx emits nothing for /git when git is disabled" {
    source "${SCRIPT_DIR}/lib/nginx.sh"
    MIRRORET_ENABLE_GIT=0
    run _nginx_git_location /srv/mirroret
    [ "$status" -eq 0 ]
    [[ "$output" != *"location /git/"* ]]
}

@test "git: a seeded mirror is cloneable over dumb HTTP" {
    local src="${TMPDIR_TEST}/src"
    _mk_source_repo "${src}"
    MIRRORET_GIT_UPSTREAM_OVERRIDE="file://${src}"
    _git_ensure_mirror "${MIRRORET_BASE_DIR}" example.com "o/r"
    # Serve the whole git store over plain static HTTP (dumb protocol).
    local port; port="$(_free_port 2>/dev/null || echo 0)"
    [ "${port}" != 0 ]
    python3 -m http.server "${port}" --bind 127.0.0.1 \
        --directory "${MIRRORET_BASE_DIR}/git" >/dev/null 2>&1 &
    local srv=$!
    local i; for i in $(seq 1 50); do curl -fsS -o /dev/null "http://127.0.0.1:${port}/" 2>/dev/null && break; sleep 0.1; done
    GIT_SMART_HTTP=0 git clone -q "http://127.0.0.1:${port}/example.com/o/r" "${TMPDIR_TEST}/httpclone"
    local rc=$?
    kill "${srv}" 2>/dev/null || true
    [ "$rc" -eq 0 ]
    [ -f "${TMPDIR_TEST}/httpclone/file.txt" ]
}

@test "git: ensure repairs a mirror whose info/refs went missing" {
    local src="${TMPDIR_TEST}/src"
    _mk_source_repo "${src}"
    MIRRORET_GIT_UPSTREAM_OVERRIDE="file://${src}"
    _git_ensure_mirror "${MIRRORET_BASE_DIR}" example.com "o/r"
    local store="${MIRRORET_BASE_DIR}/git/example.com/o/r"
    rm -f "${store}/info/refs"
    run _git_ensure_mirror "${MIRRORET_BASE_DIR}" example.com "o/r"
    [ "$status" -eq 0 ]
    [ -f "${store}/info/refs" ]
}

@test "git: ensure replaces a leftover non-mirror dir without nesting" {
    local src="${TMPDIR_TEST}/src"
    _mk_source_repo "${src}"
    local store="${MIRRORET_BASE_DIR}/git/example.com/o/r"
    mkdir -p "${store}"; echo junk > "${store}/junk.txt"
    MIRRORET_GIT_UPSTREAM_OVERRIDE="file://${src}"
    _git_ensure_mirror "${MIRRORET_BASE_DIR}" example.com "o/r"
    [ -f "${store}/HEAD" ]
    [ ! -e "${store}/junk.txt" ]
    [ -z "$(find "${store}" -name '*.mirroret-tmp.*' -print -quit)" ]
}

@test "git: an empty path is rejected" {
    ! _git_valid_repo github.com ""
}

@test "git: a .git-only path is rejected" {
    ! _git_valid_repo github.com ".git"
}

@test "git: sync refreshes a deeply-nested repo path" {
    local src="${TMPDIR_TEST}/src"
    _mk_source_repo "${src}"
    MIRRORET_GIT_UPSTREAM_OVERRIDE="file://${src}"
    _git_ensure_mirror "${MIRRORET_BASE_DIR}" gitlab.com "a/b/c/d/e/proj"
    DRY_RUN=0 write_git_sync_script "${MIRRORET_BASE_DIR}/scripts/sync-git-repos.sh"
    ( cd "${src}" && echo more >> file.txt && git commit -qam second )
    bash "${MIRRORET_BASE_DIR}/scripts/sync-git-repos.sh" >/dev/null 2>&1
    git clone -q "${MIRRORET_BASE_DIR}/git/gitlab.com/a/b/c/d/e/proj" "${TMPDIR_TEST}/deepclone"
    [ "$(wc -l < "${TMPDIR_TEST}/deepclone/file.txt")" -eq 2 ]
}
