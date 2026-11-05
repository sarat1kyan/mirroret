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
