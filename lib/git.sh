#!/usr/bin/env bash
# lib/git.sh - pull-through mirror of public upstream git repositories.
#
# Clients clone http://SERVER/git/<host>/<path>. The store holds bare
# `git clone --mirror` repos that have had `git update-server-info` run, so a
# read-only clone works over plain HTTP (the "dumb" protocol) with nginx
# serving the tree as static files - no git-http-backend / fcgiwrap needed.
#
# Source this file; do not execute it directly. Requires logging.sh.

MIRRORET_GIT_ALLOWED_HOSTS="${MIRRORET_GIT_ALLOWED_HOSTS:-github.com gitlab.com bitbucket.org codeberg.org git.sr.ht}"

# _git_valid_repo <host> <path> - true for a plain host + repo path only.
#
# Host and every path segment are strictly whitelisted. This is the single
# gate protecting every `git` invocation: host and path are interpolated into
# an https URL and passed to the git CLI, so a `..` (escape the store), a
# shell metacharacter, or a leading dash (an argument injected as a git flag,
# e.g. --upload-pack=) must all be refused.
_git_valid_repo() {
    local host="$1" path="$2"
    [[ -n "${host}" && -n "${path}" ]] || return 1
    [[ "${host}" =~ ^[A-Za-z0-9][A-Za-z0-9.-]*$ ]] || return 1
    # Strip a single trailing .git before validating the segments.
    path="${path%.git}"
    [[ "${path}" != /* && "${path}" != */ ]] || return 1
    local seg
    local IFS='/'
    for seg in ${path}; do
        [[ -n "${seg}" ]] || return 1
        [[ "${seg}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || return 1
        [[ "${seg}" == ".." || "${seg}" == "." ]] && return 1
    done
    return 0
}

# _git_mirror_url <host> <path> - the upstream URL to clone from.
_git_mirror_url() {
    local host="$1" path="$2"
    path="${path%.git}"
    printf 'https://%s/%s' "${host}" "${path}"
}

# _git_store_dir <base> <host> <path> - the bare-repo directory on disk.
# Maps 1:1 to the client URL /git/<host>/<path> (no .git suffix), so nginx is
# a plain alias and the client path resolves straight to disk.
_git_store_dir() {
    local base="$1" host="$2" path="$3"
    path="${path%.git}"
    printf '%s/git/%s/%s' "${base}" "${host}" "${path}"
}

# _git_is_mirror <dir> - true if dir is a usable bare mirror (has HEAD).
_git_is_mirror() {
    [[ -f "$1/HEAD" ]]
}

# _git_ensure_mirror <base> <host> <path> - clone the bare mirror if it is not
# already present (or is a crashed partial). Idempotent; a present, valid
# mirror is left untouched (freshness is _git_update_mirror's job).
#
# The clone goes to a temp dir and is renamed into place only on success, so
# an interrupted clone never leaves a half-mirror that nginx would serve as
# complete. MIRRORET_GIT_UPSTREAM_OVERRIDE lets tests point at a local repo.
_git_ensure_mirror() {
    local base="$1" host="$2" path="$3"
    if ! _git_valid_repo "${host}" "${path}"; then
        error "Refusing invalid git repo: ${host}/${path}"
        return 2
    fi
    local dir url
    dir="$(_git_store_dir "${base}" "${host}" "${path}")"
    if _git_is_mirror "${dir}"; then
        return 0
    fi
    # A leftover non-mirror dir (crashed previous clone) must go.
    [[ -e "${dir}" ]] && rm -rf "${dir}"
    url="${MIRRORET_GIT_UPSTREAM_OVERRIDE:-$(_git_mirror_url "${host}" "${path}")}"
    local tmp="${dir}.mirroret-tmp.$$"
    rm -rf "${tmp}"
    mkdir -p "$(dirname "${dir}")"
    # --mirror = a bare clone of every ref. -- stops any URL that slipped the
    # validator from being read as an option (defence in depth).
    if ! git clone --quiet --mirror -- "${url}" "${tmp}"; then
        rm -rf "${tmp}"
        error "git clone --mirror failed for ${url}"
        return 1
    fi
    git -C "${tmp}" update-server-info
    mv "${tmp}" "${dir}"
    return 0
}

# _git_update_mirror <dir> - refresh a bare mirror and its dumb-HTTP index.
_git_update_mirror() {
    local dir="$1"
    _git_is_mirror "${dir}" || { error "not a git mirror: ${dir}"; return 1; }
    git -C "${dir}" remote update --prune || return 1
    git -C "${dir}" update-server-info
}

# _git_host_allowed <host> - true if host is in MIRRORET_GIT_ALLOWED_HOSTS.
# The on-miss path only clones from an allowed host; `git add` may override.
_git_host_allowed() {
    local host="$1" h
    for h in ${MIRRORET_GIT_ALLOWED_HOSTS}; do
        [[ "${host}" == "${h}" ]] && return 0
    done
    return 1
}
