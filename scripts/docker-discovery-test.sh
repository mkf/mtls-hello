#!/usr/bin/env bash
# Test: two servers discover each other, extract certs via openssl s_client,
# trust them, and connect successfully via mTLS.
set -euo pipefail

PASS=0; FAIL=0
pass() { echo "  ✓ $1"; PASS=$((PASS + 1)); }
fail() { echo "  ✗ $1"; FAIL=$((FAIL + 1)); }

cleanup() { docker rm -f disco-test 2>/dev/null || true; }
trap cleanup EXIT

echo "=== Starting container ==="
docker run -d --rm --name disco-test \
    --cap-add=NET_ADMIN --cap-add=NET_RAW \
    mtls-hello-arch-installed sleep 60 >/dev/null

OUT=$(docker exec disco-test bash -c '
# Setup
mkdir -p /tmp/a/data/{hosts,purgatory} /tmp/a/certs
mkdir -p /tmp/b/data/{hosts,purgatory}  /tmp/b/certs

openssl req -x509 -newkey rsa:2048 -nodes -days 1 \
    -keyout /tmp/a/certs/srv.key -out /tmp/a/certs/srv.crt -subj /CN=alpha >/dev/null 2>&1
openssl req -x509 -newkey rsa:2048 -nodes -days 1 \
    -keyout /tmp/b/certs/srv.key -out /tmp/b/certs/srv.crt -subj /CN=beta  >/dev/null 2>&1

/usr/bin/mtls-hello 18443 /tmp/a/certs/srv.crt /tmp/a/certs/srv.key HOST_NAME=alpha --data-dir=/tmp/a/data >/tmp/a.log 2>&1 &
/usr/bin/mtls-hello 18444 /tmp/b/certs/srv.crt /tmp/b/certs/srv.key HOST_NAME=beta  --data-dir=/tmp/b/data  >/tmp/b.log 2>&1 &

sleep 6

echo "--- Discovery ---"
echo -n "alpha: "; grep -c "peer at.*18444" /tmp/a.log 2>/dev/null || echo "0"
echo -n "beta:  "; grep -c "peer at.*18443" /tmp/b.log 2>/dev/null || echo "0"

echo "--- Cert extraction ---"
# Alpha extracts beta
tmp=$(mktemp)
openssl s_client -connect 127.0.0.1:18444 -showcerts </dev/null 2>/dev/null | \
    sed -ne "/-BEGIN CERTIFICATE-/,/-END CERTIFICATE-/p" > "$tmp"
if [ -s "$tmp" ]; then
    cn=$(openssl x509 -in "$tmp" -noout -subject 2>/dev/null | sed -n "s/.*CN\\s*=\\s*//p")
    echo "alpha extracted: $cn ($(wc -c < $tmp) bytes)"
    cp "$tmp" "/tmp/a/data/purgatory/${cn}.crt"
    cp "$tmp" "/tmp/a/data/hosts/${cn}.crt"
else
    echo "alpha extraction FAILED"
fi
rm -f "$tmp"

# Beta extracts alpha
tmp=$(mktemp)
openssl s_client -connect 127.0.0.1:18443 -showcerts </dev/null 2>/dev/null | \
    sed -ne "/-BEGIN CERTIFICATE-/,/-END CERTIFICATE-/p" > "$tmp"
if [ -s "$tmp" ]; then
    cn=$(openssl x509 -in "$tmp" -noout -subject 2>/dev/null | sed -n "s/.*CN\\s*=\\s*//p")
    echo "beta extracted: $cn ($(wc -c < $tmp) bytes)"
    cp "$tmp" "/tmp/b/data/purgatory/${cn}.crt"
    cp "$tmp" "/tmp/b/data/hosts/${cn}.crt"
else
    echo "beta extraction FAILED"
fi
rm -f "$tmp"

echo "--- mTLS connection ---"
echo -n "alpha->beta: "
curl -sk --cacert /tmp/b/certs/srv.crt --cert /tmp/a/certs/srv.crt --key /tmp/a/certs/srv.key \
    https://127.0.0.1:18444/hello 2>/dev/null || echo "FAIL"
echo -n "beta->alpha: "
curl -sk --cacert /tmp/a/certs/srv.crt --cert /tmp/b/certs/srv.crt --key /tmp/b/certs/srv.key \
    https://127.0.0.1:18443/hello 2>/dev/null || echo "FAIL"

kill %1 %2 2>/dev/null || true; wait 2>/dev/null || true
' 2>&1)

echo "$OUT"
echo ""
echo "=== Results ==="
echo "$OUT" | grep -q "alpha extraction FAILED" && fail "alpha cert extraction" || pass "alpha cert extraction"
echo "$OUT" | grep -q "beta extraction FAILED" && fail "beta cert extraction" || pass "beta cert extraction"
echo "$OUT" | grep -q "alpha->beta: hello" && pass "alpha -> beta mTLS" || fail "alpha -> beta mTLS"
echo "$OUT" | grep -q "beta->alpha: hello" && pass "beta -> alpha mTLS" || fail "beta -> alpha mTLS"
echo "$OUT" | grep -q "alpha: [1-9]" && pass "alpha discovered beta" || fail "alpha discovered beta"
echo "$OUT" | grep -q "beta:  [1-9]" && pass "beta discovered alpha" || fail "beta discovered alpha"
echo ""
echo "Passed: $PASS  Failed: $FAIL"
[ "$FAIL" -eq 0 ]
