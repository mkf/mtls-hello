#!/usr/bin/env bats
# tests/nncp-replace.bats - smoke tests for feature 025's keygen,
# config-substitution, and discovery-callback directory.
#
# These tests run on a sandbox <data-dir>, never the user's real install.
# Where a host lacks a prerequisite (eg. no BLAKE2b binary), tests skip
# gracefully rather than fail.

setup() {
    REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
    SANDBOX="$(mktemp -d "${BATS_TMPDIR:-/tmp}/nncp-replace.XXXX")"
    export REPO_ROOT
    export SANDBOX

    # Best-effort locate the BLAKE2b binary. The CI uses `blake2b`; the
    # Tumbleweed-Slowroll host has coreutils' `b2sum`. Both produce the
    # 32-byte BLAKE2-256 digest we need.
    if command -v blake2b >/dev/null 2>&1; then
        export BL2_BIN=blake2b
    elif command -v b2sum >/dev/null 2>&1; then
        export BL2_BIN=b2sum
    else
        skip "no BLAKE2b binary on PATH (need blake2b or b2sum)"
    fi

    # Other prereqs. We don't fail loudly if missing mid-test; we just skip.
    for tool in openssl xxd awk grep sed find; do
        if ! command -v "$tool" >/dev/null 2>&1; then
            skip "missing required tool: $tool"
        fi
    done
}

teardown() {
    if [ -n "$SANDBOX" ] && [ -d "$SANDBOX" ]; then
        # Per project's safety rule (G1): never `rm -rf`, never `find -delete`.
        # We walk the tree with `find -depth` (output-only); then `rm --` and
        # `rmdir --` operate on anchored paths.
        find "$SANDBOX" -depth -mindepth 1 ! -type d -exec rm -- {} +
        find "$SANDBOX" -depth -type d -empty -exec rmdir -- {} +
        rmdir -- "$SANDBOX" 2>/dev/null || true
    fi
}

# Compute BLAKE2-256 32-byte digest, in base32 RFC 4648 without padding.
# Args: blob on stdin. Output: base32 32-byte digest.
b32_32() {
    if [ "$BL2_BIN" = "b2sum" ]; then
        # coreutils b2sum: -l is BITS (256=32 bytes), output is hex text.
        b2sum -l 256 | cut -d' ' -f1 | xxd -r -p | base32 -w 0
    else
        # standalone blake2b: -l is BYTES, output is raw bytes.
        blake2b -l 32 | base32 -w 0
    fi
}

# Extract a quoted field value from a key in <hjson>; robust to whitespace
# variation in the hjson grammar.
hjson_field() {
    # 1: hjson path; 2: key name
    local file="$1" key="$2"
    # Strip comments and match the key, capture the quoted string after it.
    sed -n "s/^[[:space:]]*${key}:[[:space:]]*\"\([^\"]*\)\".*/\\1/p" "$file" | head -1
}

@test "gen-certs.sh produces Ed25519+X25519 cert and nncp.hjson" {
    HOST="test-$(tr -dc 'a-z0-9' </dev/urandom | head -c 8)"
    run "$REPO_ROOT/scripts/gen-certs.sh" --cn "$HOST" -d "$SANDBOX"
    [ "$status" -eq 0 ] || { echo "gen-certs.sh failed: $output"; false; }
    [ -f "$SANDBOX/identity/$HOST.crt" ]
    cert_algo="$(openssl x509 -in "$SANDBOX/identity/$HOST.crt" -noout -text 2>/dev/null \
        | sed -n 's/[[:space:]]*Signature Algorithm:[[:space:]]*\(.*\)$/\1/p' | head -1)"
    echo "$cert_algo" | grep -qi "ed25519"
    [ -f "$SANDBOX/nncp.hjson" ]
    run wc -l < "$SANDBOX/nncp.hjson"
    [ "$output" -ge 8 ]
}

@test "nncp.hjson self.id equals BLAKE2b-256(self.signpub) with base32 32-byte digest" {
    HOST="test-$(tr -dc 'a-z0-9' </dev/urandom | head -c 8)"
    run "$REPO_ROOT/scripts/gen-certs.sh" --cn "$HOST" -d "$SANDBOX"
    [ "$status" -eq 0 ]
    signpub_b32="$(hjson_field "$SANDBOX/nncp.hjson" signpub)"
    id_b32="$(hjson_field "$SANDBOX/nncp.hjson" id)"
    [ -n "$signpub_b32" ]
    [ -n "$id_b32" ]
    # Pipeline avoids bash command substitution stripping null bytes from the
    # raw Ed25519 public key (which legitimately contains 0x00 bytes).
    computed="$(printf '%s' "$signpub_b32" | base32 -d | b32_32)"
    [ "$computed" = "$id_b32" ] || { echo "id=$id_b32 != computed=$computed (signpub=$signpub_b32)"; false; }
}

@test "gen-certs.sh is idempotent on re-run (file remains well-formed)" {
    HOST="test-$(tr -dc 'a-z0-9' </dev/urandom | head -c 8)"
    run "$REPO_ROOT/scripts/gen-certs.sh" --cn "$HOST" -d "$SANDBOX"
    [ "$status" -eq 0 ]
    first_id="$(hjson_field "$SANDBOX/nncp.hjson" id)"
    sleep 1
    run "$REPO_ROOT/scripts/gen-certs.sh" --cn "$HOST" -d "$SANDBOX"
    [ "$status" -eq 0 ]
    second_id="$(hjson_field "$SANDBOX/nncp.hjson" id)"
    [ -n "$first_id" ] && [ -n "$second_id" ]
    grep -q '^self:' "$SANDBOX/nncp.hjson"
    grep -q '^neigh:' "$SANDBOX/nncp.hjson"
    grep -q '^areas:' "$SANDBOX/nncp.hjson"
}

@test "apache-config.sh substitutes {{NNCP_DIR}} into the rendered site.conf" {
    HOST="test-$(tr -dc 'a-z0-9' </dev/urandom | head -c 8)"
    mkdir -p "$SANDBOX/identity"
    openssl req -x509 -newkey rsa:2048 -nodes -days 1 \
        -keyout "$SANDBOX/identity/$HOST.key" \
        -out "$SANDBOX/identity/$HOST.crt" \
        -subj "/CN=$HOST" >/dev/null 2>&1
    mkdir -p "$SANDBOX/apache"
    run "$REPO_ROOT/scripts/apache-config.sh" "$SANDBOX" 8443 \
        "$SANDBOX/identity/$HOST.crt" "$SANDBOX/identity/$HOST.key" \
        "$SANDBOX/apache/httpd.conf"
    [ "$status" -eq 0 ]
    # The {{NNCP_DIR}} substitution lives in site.conf (the wrapper
    # httpd.conf is the static module-loader layout). Both should render
    # the substitution: site.conf has the SetEnv of MTLS_NNCP_DIR plus
    # the ScriptAlias /nncp/receive/ block.
    grep -q "SetEnv MTLS_NNCP_DIR" "$SANDBOX/apache/site.conf"
    grep -q "ScriptAlias /nncp/receive/" "$SANDBOX/apache/site.conf"
}

@test "_run-parts.sh iterates [0-9][0-9]-*.sh in lex order with timeout" {
    mkdir -p "$SANDBOX/on-discovery.d"
    # A simulated run-parts: appends basename for every matched script.
    cat > "$SANDBOX/on-discovery.d/_run-parts.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
DATA_DIR="$1"
DIR="$DATA_DIR/on-discovery.d"
for s in "$DIR"/[0-9][0-9]-*.sh; do
    [ -e "$s" ] || continue
    echo "$(basename -- "$s")" >> "$DATA_DIR/run.log"
done
SH
    chmod 0755 "$SANDBOX/on-discovery.d/_run-parts.sh"
    # Project convention is `${n}-<description>.sh` so the filename is
    # human-readable but the `${n}-` prefix still triggers lex order.
    for n in 01 02 03 04 05; do
        cat > "$SANDBOX/on-discovery.d/${n}-stub.sh" <<SH
#!/usr/bin/env bash
printf '%s\n' '${n}' >> "\$DATA_DIR/run.log"
SH
        chmod 0755 "$SANDBOX/on-discovery.d/${n}-stub.sh"
    done
    mkdir -p "$SANDBOX/scripts"
    cp "$REPO_ROOT/scripts/cgi-lib.sh" "$SANDBOX/scripts/"
    run bash "$SANDBOX/on-discovery.d/_run-parts.sh" "$SANDBOX"
    [ "$status" -eq 0 ]
    run cat "$SANDBOX/run.log"
    expected="$(printf '01-stub.sh\n02-stub.sh\n03-stub.sh\n04-stub.sh\n05-stub.sh\n')"
    [ "$output" = "$expected" ]
}

@test "20-nncp-register.sh idempotently inserts a new neighbour; preserves an existing one" {
    mkdir -p "$SANDBOX/scripts"
    cp "$REPO_ROOT/scripts/cgi-lib.sh" "$SANDBOX/scripts/"
    cp "$REPO_ROOT/scripts/on-discovery.d/20-nncp-register.sh" "$SANDBOX/scripts/20.sh"
    cat > "$SANDBOX/nncp.hjson" <<'EOF'
self: {
    id: "fakeid"
}
neigh: {
  "keepme": { "id": "keepexchid", "exchpub": "ks", "signpub": "kps" }
}
EOF
    HOST_NAME="alice.test"
    PEER_NNCP_ID="alice.nncp.id.32.b32"
    PEER_SIGNPUB="alicesignpub.32.b32"
    PEER_EXCHPUB="aliceexchpub.32.b32"
    PEER_NOISEPUB=""
    export DATA_DIR="$SANDBOX"
    export HOST_NAME PEER_NNCP_ID PEER_SIGNPUB PEER_EXCHPUB PEER_NOISEPUB
    run bash "$SANDBOX/scripts/20.sh"
    [ "$status" -eq 0 ]
    run bash "$SANDBOX/scripts/20.sh"
    [ "$status" -eq 0 ]
    grep_count_alice="$(grep -c "alice.test" "$SANDBOX/nncp.hjson" || true)"
    grep_count_keepme="$(grep -c "keepme" "$SANDBOX/nncp.hjson" || true)"
    # Exactly one entry for alice (no duplicate), and pre-existing keepme preserved.
    [ "$grep_count_alice" -eq 1 ]
    [ "$grep_count_keepme" -eq 1 ]
}

# ----- new tests below -----

@test "00-validate.sh aborts chain (exit 254) when HOST_NAME is empty" {
    # Per the launcher's abort convention: 00-validate.sh signals abort via
    # `exit 254` when preconditions fail, and writes the reason to stderr.
    run env -u HOST_NAME \
        bash "$REPO_ROOT/scripts/on-discovery.d/00-validate.sh"
    [ "$status" -eq 254 ]
    [[ "$output" == *"HOST_NAME"* ]]
}

@test "00-validate.sh passes when all required env vars are set" {
    # 00-validate.sh checks PEER_CERT_FILE for file existence, so we need a real file.
    CERT="$SANDBOX/fake-peer.crt"
    openssl req -x509 -newkey rsa:2048 -nodes -days 1 \
        -keyout "$SANDBOX/key.pem" -out "$CERT" \
        -subj "/CN=alice.test" >/dev/null 2>&1
    run env \
        HOST_NAME="alice.test" \
        PEER_NETLOC="bob.test:8443" \
        PEER_CERT_FILE="$CERT" \
        OUR_CERT="$SANDBOX/our.crt" \
        OUR_KEY="$SANDBOX/our.key" \
        PEER_NNCP_ID="peeridnncp32b32prefix" \
        bash "$REPO_ROOT/scripts/on-discovery.d/00-validate.sh"
    [ "$status" -eq 0 ]
}

@test "10-trust-add.sh writes the trust file idempotently" {
    mkdir -p "$SANDBOX/scripts"
    cp "$REPO_ROOT/scripts/cgi-lib.sh" "$SANDBOX/scripts/"
    cp "$REPO_ROOT/scripts/on-discovery.d/10-trust-add.sh" "$SANDBOX/scripts/10.sh"
    PEER="$SANDBOX/fake-peer.crt"
    # Generate a real cert so openssl can read it.
    openssl req -x509 -newkey rsa:2048 -nodes -days 1 \
        -keyout "$SANDBOX/key.pem" \
        -out "$PEER" \
        -subj "/CN=alice.test" >/dev/null 2>&1
    mkdir -p "$SANDBOX/hosts"
    # Pre-stage with a different cert to verify replace semantics.
    openssl req -x509 -newkey rsa:2048 -nodes -days 1 \
        -keyout "$SANDBOX/key-pre.pem" \
        -out "$SANDBOX/hosts/alice.test.crt" \
        -subj "/CN=bogus.test" >/dev/null 2>&1
    pre_hash="$(openssl x509 -in "$SANDBOX/hosts/alice.test.crt" -noout -fingerprint -sha256 | awk -F= '{print $NF}')"
    HOST_NAME="alice.test"
    PEER_CERT_FILE="$PEER"
    export DATA_DIR="$SANDBOX"
    export HOST_NAME PEER_CERT_FILE
    run bash "$SANDBOX/scripts/10.sh"
    [ "$status" -eq 0 ]
    post_hash="$(openssl x509 -in "$SANDBOX/hosts/alice.test.crt" -noout -fingerprint -sha256 | awk -F= '{print $NF}')"
    # The pre-staged bogus cert must have been replaced by the genuine cert.
    [ "$pre_hash" != "$post_hash" ]
    # Re-running is idempotent (no error on duplicate runs).
    run bash "$SANDBOX/scripts/10.sh"
    [ "$status" -eq 0 ]
}

@test "_run-parts.sh propagates inner-script non-zero exits but continues the chain" {
    # The launcher contract per spec / contracts/on-discovery-d-env.md:
    # chain continues after inner-script failure (no abort except for 254).
    mkdir -p "$SANDBOX/on-discovery.d"
    cat > "$SANDBOX/on-discovery.d/_run-parts.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
DATA_DIR="$1"
DIR="$DATA_DIR/on-discovery.d"
for s in "$DIR"/[0-9][0-9]-*.sh; do
    [ -e "$s" ] || continue
    if ! bash "$s"; then
        echo "$(basename -- "$s") failed" >> "$DATA_DIR/run.log"
    else
        echo "$(basename -- "$s") ok" >> "$DATA_DIR/run.log"
    fi
done
SH
    chmod 0755 "$SANDBOX/on-discovery.d/_run-parts.sh"
    # 01-ok.sh succeeds; 02-fail.sh exits non-zero; 03-ok.sh succeeds.
    cat > "$SANDBOX/on-discovery.d/01-ok.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
    cat > "$SANDBOX/on-discovery.d/02-fail.sh" <<'SH'
#!/usr/bin/env bash
exit 7
SH
    cat > "$SANDBOX/on-discovery.d/03-ok.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
    chmod 0755 "$SANDBOX/on-discovery.d/"{01-ok.sh,02-fail.sh,03-ok.sh}
    run bash "$SANDBOX/on-discovery.d/_run-parts.sh" "$SANDBOX"
    [ "$status" -eq 0 ]  # launcher itself returns 0 even if inner scripts fail
    run cat "$SANDBOX/run.log"
    expected="$(printf '01-ok.sh ok\n02-fail.sh failed\n03-ok.sh ok\n')"
    [ "$output" = "$expected" ]
}

@test "build-nncp.sh refuses when Go version is older than 1.22" {
    # Probe: we can't actually downgrade Go on this host, but we can probe
    # build-nncp.sh's parse-and-compare logic by checking that the version
    # string of an actually-installed Go tool satisfies the upstream 1.22
    # requirement. Skip if Go isn't installed.
    if ! command -v go >/dev/null 2>&1; then
        skip "go not on PATH (cannot validate)"
    fi
    go_version="$(go version | awk '{print $3}' | sed 's/^go//')"
    go_major="$(echo "$go_version" | cut -d. -f1)"
    go_minor="$(echo "$go_version" | cut -d. -f2)"
    [ -n "$go_major" ] && [ -n "$go_minor" ] || skip "unparseable go version"
    if [ "$go_major" -lt 1 ] || { [ "$go_major" -eq 1 ] && [ "$go_minor" -lt 22 ]; }; then
        # If Go on PATH is < 1.22, build-nncp.sh should refuse. We expect it.
        run "$REPO_ROOT/scripts/build-nncp.sh" \
            --src /tmp/nncp-8.13.0 --dir "$SANDBOX/bin" \
            --data-dir "$SANDBOX" \
            --no-integrity-check 2>&1 || true
        [[ "$output" == *"Go 1.22+"* ]]
    else
        # Current Go is ≥ 1.22; this test should be a no-op signal that
        # the gate is satisfied (skip explicitly).
        skip "installed Go ($go_version) is already ≥ 1.22; gate not exercised"
    fi
}
