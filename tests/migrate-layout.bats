#!/usr/bin/env bats

# Safe-deletion helpers (no rm -rf / rm -f anywhere).
# shellcheck source=scripts/cleanup-common.sh
. scripts/cleanup-common.sh

setup() {
    TEST_DIR=$(mktemp -d)
    DATA_DIR="$TEST_DIR/data"
    # Build a legacy certs/ tree.
    mkdir -p "$DATA_DIR/certs/certs" "$DATA_DIR/certs/private" \
             "$DATA_DIR/certs/hosts" "$DATA_DIR/certs/purgatory"
    printf 'CERTDATA\n' > "$DATA_DIR/certs/certs/server.crt"
    printf 'KEYDATA\n' > "$DATA_DIR/certs/private/server.key"
    printf 'PEER1\n' > "$DATA_DIR/certs/hosts/peer1.crt"
    printf 'PEER2FP\n' > "$DATA_DIR/certs/purgatory/peer2.deadbeef.crt"
}

teardown() {
    remove_git_repo "$TEST_DIR" 2>/dev/null || true
    rmdir -- "$TEST_DIR" || echo "warning: could not rmdir $TEST_DIR" >&2
}

@test "no-op when no legacy certs/ directory exists" {
    remove_file_safe "$DATA_DIR/certs/certs/server.crt" "$DATA_DIR/certs/private/server.key" \
        "$DATA_DIR/certs/hosts/peer1.crt" "$DATA_DIR/certs/purgatory/peer2.deadbeef.crt"
    rmdir -- "$DATA_DIR/certs/certs" "$DATA_DIR/certs/private" "$DATA_DIR/certs/hosts" "$DATA_DIR/certs/purgatory" 2>/dev/null || true
    rmdir -- "$DATA_DIR/certs" 2>/dev/null || true
    run bash scripts/migrate-layout.sh "$DATA_DIR" "testhost"
    [ "$status" -eq 0 ]
    [ ! -d "$DATA_DIR/certs" ]
}

@test "full legacy tree migrates to flat layout and removes certs/" {
    run bash scripts/migrate-layout.sh "$DATA_DIR" "testhost"
    [ "$status" -eq 0 ]
    [ "$(cat "$DATA_DIR/identity/testhost.crt")" = "CERTDATA" ]
    [ "$(cat "$DATA_DIR/identity/testhost.key")" = "KEYDATA" ]
    [ "$(cat "$DATA_DIR/hosts/peer1.crt")" = "PEER1" ]
    [ "$(cat "$DATA_DIR/purgatory/peer2.deadbeef.crt")" = "PEER2FP" ]
    [ ! -d "$DATA_DIR/certs" ]
}

@test "second run is a no-op (idempotent)" {
    run bash scripts/migrate-layout.sh "$DATA_DIR" "testhost"
    [ "$status" -eq 0 ]
    run bash scripts/migrate-layout.sh "$DATA_DIR" "testhost"
    [ "$status" -eq 0 ]
    [ "$(cat "$DATA_DIR/identity/testhost.crt")" = "CERTDATA" ]
}

@test "partial legacy layout (cert only) migrates without failure" {
    remove_file_safe "$DATA_DIR/certs/private/server.key"
    run bash scripts/migrate-layout.sh "$DATA_DIR" "testhost"
    [ "$status" -eq 0 ]
    [ -f "$DATA_DIR/identity/testhost.crt" ]
    [ ! -f "$DATA_DIR/identity/testhost.key" ]
    [ ! -d "$DATA_DIR/certs" ]
}

@test "existing differing target is kept, no overwrite" {
    mkdir -p "$DATA_DIR/identity"
    printf 'NEWDATA\n' > "$DATA_DIR/identity/testhost.crt"
    run bash scripts/migrate-layout.sh "$DATA_DIR" "testhost"
    [ "$status" -eq 0 ]
    [ "$(cat "$DATA_DIR/identity/testhost.crt")" = "NEWDATA" ]
    # legacy cert file remains (not deleted when target differs)
    [ -f "$DATA_DIR/certs/certs/server.crt" ]
}

@test "non-empty leftover legacy dir is kept with a warning" {
    mkdir -p "$DATA_DIR/certs/extra"
    printf 'X\n' > "$DATA_DIR/certs/extra/stray.txt"
    run bash scripts/migrate-layout.sh "$DATA_DIR" "testhost"
    [ "$status" -eq 0 ]
    [ -f "$DATA_DIR/certs/extra/stray.txt" ]
    [[ "$output" == *"leaving non-empty directory"* ]]
}

@test "hostname is sanitized to a safe filename" {
    run bash scripts/migrate-layout.sh "$DATA_DIR" "host with spaces!"
    [ "$status" -eq 0 ]
    [ -f "$DATA_DIR/identity/host_with_spaces_.crt" ]
}

@test "BUG-001: cleanup_pkgroot removes per-distro metadata without warnings" {
    # Source the packaging helpers (runs from repo root).
    . scripts/package-common.sh
    local root
    root="$(mktemp -d)"
    mkdir -p "$root/usr/bin" "$root/usr/lib/systemd/user" \
             "$root/var/lib/mtls-hello/handlers" "$root/var/lib/mtls-hello/scripts" \
             "$root/DEBIAN"
    install -m 755 /bin/true "$root/usr/bin/mtls-hello"
    printf 'x\n' > "$root/usr/lib/systemd/user/mtls-hello.service"
    printf 'x\n' > "$root/var/lib/mtls-hello/handlers/bundle.post.sh"
    printf 'x\n' > "$root/var/lib/mtls-hello/scripts/on-discover.sh"
    printf 'control\n' > "$root/DEBIAN/control"
    printf 'postinst\n' > "$root/DEBIAN/postinst"

    run cleanup_pkgroot "$root"
    [ "$status" -eq 0 ]
    [ ! -d "$root" ]
    [[ "$output" != *"warning"* ]]

    # Arch layout: .PKGINFO / .INSTALL at the root.
    local root2
    root2="$(mktemp -d)"
    mkdir -p "$root2/usr/bin" "$root2/var/lib/mtls-hello/handlers"
    install -m 755 /bin/true "$root2/usr/bin/mtls-hello"
    printf 'x\n' > "$root2/var/lib/mtls-hello/handlers/bundle.post.sh"
    printf 'PKGINFO\n' > "$root2/.PKGINFO"
    printf 'INSTALL\n' > "$root2/.INSTALL"

    run cleanup_pkgroot "$root2"
    [ "$status" -eq 0 ]
    [ ! -d "$root2" ]
    [[ "$output" != *"warning"* ]]
}
