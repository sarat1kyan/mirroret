#!/usr/bin/env bats
# Tests for scripts/verify-mirror.sh - the post-sync self-test that walks
# every published Release and checks each file it lists is on disk.
#
# These are the guard rails for the "server publishes a Release full of
# 404s" bug we chased for a week. If verify-mirror ever misses a broken
# mirror, one of these tests must fail.

load 'test_helpers'

setup() {
    load_lib
    TMPDIR_TEST="$(mktemp -d)"
}

teardown() {
    [[ -n "${TMPDIR_TEST:-}" ]] && rm -rf "${TMPDIR_TEST}"
}

_write_release() {
    # $1 = suite dir, $2 = list of "path SIZE" lines
    local dir="$1" entries="$2"
    mkdir -p "$dir"
    {
        echo "Suite: test"
        echo "Codename: test"
        echo "Architectures: amd64"
        echo "Components: main"
        echo "SHA256:"
        while IFS= read -r line; do
            [[ -z "$line" ]] && continue
            local path size sha
            path="${line% *}"
            size="${line#* }"
            sha="$(printf '%040d' 0)$(printf '%024d' 0)"  # 64 hex chars
            printf " %s %s %s\n" "$sha" "$size" "$path"
        done <<< "$entries"
    } > "${dir}/Release"
}

@test "verify-mirror: an intact mirror exits 0" {
    local base="${TMPDIR_TEST}/srv" suite="${TMPDIR_TEST}/srv/apt/ubuntu/dists/noble"
    _write_release "$suite" \
"main/binary-amd64/Packages 5
main/cnf/Commands-amd64 3"
    mkdir -p "${suite}/main/binary-amd64" "${suite}/main/cnf"
    printf 'hello' > "${suite}/main/binary-amd64/Packages"     # 5 bytes
    printf 'bye' > "${suite}/main/cnf/Commands-amd64"           # 3 bytes

    run "${SCRIPT_DIR}/scripts/verify-mirror.sh" --base-dir "$base"
    [ "$status" -eq 0 ]
    [[ "$output" == *"every published Release is complete"* ]]
}

@test "verify-mirror: a missing index is caught and named" {
    # This is the exact class of bug that let dep11/cnf 404s ship silently.
    local base="${TMPDIR_TEST}/srv" suite="${TMPDIR_TEST}/srv/apt/ubuntu/dists/noble"
    _write_release "$suite" \
"main/binary-amd64/Packages 5
main/dep11/Components-amd64.yml 42"
    mkdir -p "${suite}/main/binary-amd64"
    printf 'hello' > "${suite}/main/binary-amd64/Packages"
    # Deliberately do NOT create main/dep11/Components-amd64.yml.

    run "${SCRIPT_DIR}/scripts/verify-mirror.sh" --base-dir "$base"
    [ "$status" -eq 2 ]
    [[ "$output" == *"missing: main/dep11/Components-amd64.yml"* ]]
    [[ "$output" == *"clients WILL 404"* ]]
}

@test "verify-mirror: a wrong-size file is caught" {
    local base="${TMPDIR_TEST}/srv" suite="${TMPDIR_TEST}/srv/apt/ubuntu/dists/noble"
    _write_release "$suite" \
"main/binary-amd64/Packages 100"
    mkdir -p "${suite}/main/binary-amd64"
    printf 'short' > "${suite}/main/binary-amd64/Packages"      # 5 bytes not 100

    run "${SCRIPT_DIR}/scripts/verify-mirror.sh" --base-dir "$base"
    [ "$status" -eq 2 ]
    [[ "$output" == *"wrong size"* ]]
    [[ "$output" == *"have=5 want=100"* ]]
}

@test "verify-mirror: --json emits a machine-readable report" {
    local base="${TMPDIR_TEST}/srv" suite="${TMPDIR_TEST}/srv/apt/ubuntu/dists/noble"
    _write_release "$suite" \
"main/binary-amd64/Packages 5"
    mkdir -p "${suite}/main/binary-amd64"
    printf 'hello' > "${suite}/main/binary-amd64/Packages"

    run "${SCRIPT_DIR}/scripts/verify-mirror.sh" --base-dir "$base" --json
    [ "$status" -eq 0 ]
    python3 -c "import json,sys; d=json.loads(sys.argv[1]); assert d['ok'] is True" "$output"
}

@test "verify-mirror: honours --flavor and --suite filters" {
    local base="${TMPDIR_TEST}/srv"
    local sn="${base}/apt/ubuntu/dists/noble"
    local sj="${base}/apt/ubuntu/dists/jammy"
    _write_release "$sn" "main/binary-amd64/Packages 5"
    _write_release "$sj" "main/binary-amd64/Packages 5"
    mkdir -p "${sn}/main/binary-amd64" "${sj}/main/binary-amd64"
    printf 'hello' > "${sn}/main/binary-amd64/Packages"
    # jammy deliberately missing - would fail without a filter.

    run "${SCRIPT_DIR}/scripts/verify-mirror.sh" --base-dir "$base" --suite noble
    [ "$status" -eq 0 ]

    run "${SCRIPT_DIR}/scripts/verify-mirror.sh" --base-dir "$base" --suite jammy
    [ "$status" -eq 2 ]
}

@test "verify-mirror: an unsigned Release is honoured (SHA256 is the only truth)" {
    # An internal archive may ship an unsigned Release. It still has a
    # SHA256 block, and clients still care about missing files.
    local base="${TMPDIR_TEST}/srv" suite="${TMPDIR_TEST}/srv/apt/ubuntu/dists/noble"
    _write_release "$suite" "main/binary-amd64/Packages 5"
    mkdir -p "${suite}/main/binary-amd64"
    printf 'hello' > "${suite}/main/binary-amd64/Packages"

    run "${SCRIPT_DIR}/scripts/verify-mirror.sh" --base-dir "$base"
    [ "$status" -eq 0 ]
}

@test "verify-mirror: an InRelease (clearsigned) parses like Release" {
    local base="${TMPDIR_TEST}/srv" suite="${TMPDIR_TEST}/srv/apt/ubuntu/dists/noble"
    mkdir -p "${suite}/main/binary-amd64"
    printf 'hello' > "${suite}/main/binary-amd64/Packages"
    {
        echo "-----BEGIN PGP SIGNED MESSAGE-----"
        echo "Hash: SHA256"
        echo
        echo "Suite: test"
        echo "Codename: test"
        echo "Architectures: amd64"
        echo "Components: main"
        echo "SHA256:"
        printf " %s 5 main/binary-amd64/Packages\n" "$(printf '%064d' 0)"
        echo "-----BEGIN PGP SIGNATURE-----"
        echo "junk"
        echo "-----END PGP SIGNATURE-----"
    } > "${suite}/InRelease"

    run "${SCRIPT_DIR}/scripts/verify-mirror.sh" --base-dir "$base"
    [ "$status" -eq 0 ]
    [[ "$output" == *"InRelease"* ]]
}

@test "verify-mirror: no apt tree at all is a usage error, not a false OK" {
    run "${SCRIPT_DIR}/scripts/verify-mirror.sh" --base-dir "${TMPDIR_TEST}/nope"
    [ "$status" -eq 3 ]
}

@test "mirroretctl: verify subcommand delegates to verify-mirror.sh" {
    grep -q 'cmd_verify' "${SCRIPT_DIR}/mirroretctl"
    grep -q 'verify)  *cmd_verify' "${SCRIPT_DIR}/mirroretctl"
}

@test "apt sync script: runs verify-mirror.sh on success" {
    # Every mirror-of-Ubuntu sync should end with an integrity report, so the
    # class of bug we spent a week chasing shows up on the SERVER right when
    # it happens rather than on a client hours later.
    grep -q 'scripts/verify-mirror.sh' "${SCRIPT_DIR}/lib/apt.sh"
    grep -q 'integrity check' "${SCRIPT_DIR}/lib/apt.sh"
}
