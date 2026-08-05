#!/usr/bin/env bats
# End-to-end tests for mtls-hello.
# Each test starts and stops its own server on a scratch port.

export MTLS_PORT="${MTLS_PORT:-18443}"

# Self-extracting installer cache for the installer tests.
SE_INSTALLER_CACHE="/tmp/mtls-self-extract-installer"

get_self_extract_installer() {
  # BATS runs tests with `set -e`; the conditional checks below are safe,
  # but command substitutions and the `||` in the cached-file test can
  # still trip it in some bash versions, so we temporarily disable it.
  local old_state=$-
  set +e
  local cached=""
  if [ -f "$SE_INSTALLER_CACHE" ]; then
    cached=$(cat "$SE_INSTALLER_CACHE")
  fi
  if [ ! -f "$SE_INSTALLER_CACHE" ] || [ ! -f "$cached" ]; then
    LD_LIBRARY_PATH="" just self-extract >/dev/null
    ls -t mtls-hello-installer-*.sh | head -1 > "$SE_INSTALLER_CACHE"
  fi
  cat "$SE_INSTALLER_CACHE"
  if [[ "$old_state" == *e* ]]; then set -e; fi
}

setup_file() {
  rm -f "$SE_INSTALLER_CACHE" mtls-hello-installer-*.sh 2>/dev/null || true
}

teardown_file() {
  rm -f "$SE_INSTALLER_CACHE" mtls-hello-installer-*.sh 2>/dev/null || true
}

# Globals for per-test self-signed certificates. Generated in setup().
SERVER_CERT=""
SERVER_KEY=""
CLIENT_CERT=""
CLIENT_KEY=""

# Generate a fresh self-signed server and client certificate pair for the
# current test. No CA is used; the server's cert is its own trust anchor.
mkfixture_certs() {
  local dir="${1:-$(mktemp -d)}"
  mkdir -p "$dir"
  openssl req -x509 -newkey rsa:2048 -nodes -days 1 \
    -keyout "$dir/server.key" -out "$dir/server.crt" \
    -subj "/CN=localhost" >/dev/null 2>&1
  openssl req -x509 -newkey rsa:2048 -nodes -days 1 \
    -keyout "$dir/client.key" -out "$dir/client.crt" \
    -subj "/CN=test-client" >/dev/null 2>&1
  chmod 600 "$dir/server.key" "$dir/client.key"
  SERVER_CERT="$dir/server.crt"
  SERVER_KEY="$dir/server.key"
  CLIENT_CERT="$dir/client.crt"
  CLIENT_KEY="$dir/client.key"
}

start_server() {
  local port args
  port="${1:-$MTLS_PORT}"
  shift || true
  args="$@"

  

  # Ensure the binary is up-to-date; if already built this is a no-op.
  dub build --compiler=ldc2 --skip-registry=standard 2>/dev/null || true

  local bin_dir bin_name
  bin_dir="$(dub describe --data=target-path 2>/dev/null | tail -1)"
  bin_dir="${bin_dir:-.}"
  bin_name="$(dub describe --data=target-name 2>/dev/null | tail -1)"
  bin_name="${bin_name:-mtls-hello}"
  # Fallback: look for the binary in the current directory.
  local binary="$bin_dir/$bin_name"
  if [ ! -x "$binary" ]; then
    binary="$(pwd)/mtls-hello"
  fi
  if [ ! -x "$binary" ]; then
    echo "Error: cannot find mtls-hello binary (tried $bin_dir/$bin_name and ./mtls-hello)" >&2
    return 1
  fi

  # Ensure the test trust dirs are available (e.g., after an explicit teardown).
  if [[ -z "$TRUST_DIR" ]]; then
    setup_trust_dirs
  fi

  SERVER_PID=""
  "$binary" "$port" \
    "$SERVER_CERT" "$SERVER_KEY" \
    --trust-dir "$TRUST_DIR" \
    --purgatory-dir "$PURGATORY_DIR" \
    $args >/tmp/mtls-server-$$.log 2>&1 &
  SERVER_PID=$!

  # Wait until the port accepts TCP connections.
  local _i
  for _i in $(seq 1 100); do
    # Try bash /dev/tcp first; fall back to nc.
    if (exec 5<>"/dev/tcp/127.0.0.1/$port") 2>/dev/null; then
      exec 5>&- 5<&- 2>/dev/null || true
      return 0
    fi
    if command -v nc >/dev/null 2>&1 && nc -z 127.0.0.1 "$port" 2>/dev/null; then
      return 0
    fi
    if ! kill -0 "$SERVER_PID" 2>/dev/null; then
      echo "server died (pid $SERVER_PID) before accepting connections" >&2
      cat /tmp/mtls-server-$$.log >&2 || true
      return 1
    fi
    sleep 0.1
  done

  echo "server failed to start on port $port" >&2
  cat /tmp/mtls-server-$$.log >&2 || true
  return 1
}

stop_server() {
  [[ -n "$SERVER_PID" ]] && kill "$SERVER_PID" 2>/dev/null || true
  wait "$SERVER_PID" 2>/dev/null || true
}

# Create a fresh trust/purgatory directory pair and seed the trust store with
# the test client certificate. Sets TRUST_DIR, PURGATORY_DIR, and TRUST_BASE_DIR.
setup_trust_dirs() {
  TRUST_BASE_DIR="$(mktemp -d)"
  TRUST_DIR="$TRUST_BASE_DIR/hosts"
  PURGATORY_DIR="$TRUST_BASE_DIR/purgatory"
  mkdir -p "$TRUST_DIR" "$PURGATORY_DIR"
  cp "$CLIENT_CERT" "$TRUST_DIR/test-client.crt"
}

# Create a git fixture for the multi-repo sync demo.
# Returns the base directory path.
# Build a fixture of bare repositories under two REPOS_ROOT trees.
# Returns $base where:
#   $base/local/*.git  = local host's bare repos
#   $base/peer/*.git   = peer host's bare repos
#   $base/seed/        = temporary working tree used to seed the bare repos
# States:
#   alpha: local ahead of peer by 1 commit (local main is a descendant of peer main)
#   beta:  peer ahead of local by 1 commit (peer main is a descendant of local main)
#   gamma: diverged — both have unique commits on main
#   delta: local-only repository (no peer counterpart)
#   (tag) local-tag-v1 on local gamma, missing from peer gamma
mkfixture_bare() {
  local base="$1"
  rm -rf "$base"
  mkdir -p "$base"

  local seed="$base/seed"
  mkdir -p "$seed"
  git -C "$seed" init --quiet
  git -C "$seed" config user.email "test@example.com"
  git -C "$seed" config user.name "Test"
  echo "base" > "$seed/README"
  git -C "$seed" add README
  git -C "$seed" commit -m "base" --quiet
  # Ensure the seed has a local 'main' branch at the base commit so that
  # subsequent 'git checkout main' commands work regardless of git defaults.
  git -C "$seed" checkout -B main --quiet

  # Create bare repos on both sides.
  for side in local peer; do
    mkdir -p "$base/$side"
    for name in alpha beta gamma delta; do
      git init --bare "$base/$side/${name}.git" --quiet
    done
  done

  # Push the base commit to all repos as main.
  for side in local peer; do
    for name in alpha beta gamma delta; do
      git -C "$seed" push --quiet "$base/$side/${name}.git" HEAD:main
    done
  done

  # alpha: local ahead by one commit.
  git -C "$seed" checkout -b alpha-local --quiet
  echo "alpha-local" > "$seed/alpha.txt"
  git -C "$seed" add alpha.txt
  git -C "$seed" commit -m "alpha local advance" --quiet
  git -C "$seed" push --quiet "$base/local/alpha.git" alpha-local:main

  # beta: peer ahead by one commit.
  git -C "$seed" checkout main --quiet
  git -C "$seed" checkout -b beta-peer --quiet
  echo "beta-peer" > "$seed/beta.txt"
  git -C "$seed" add beta.txt
  git -C "$seed" commit -m "beta peer advance" --quiet
  git -C "$seed" push --quiet "$base/peer/beta.git" beta-peer:main

  # gamma: diverged — both sides have unique commits on main.
  git -C "$seed" checkout main --quiet
  git -C "$seed" checkout -b gamma-local --quiet
  echo "gamma-local" > "$seed/gamma-local.txt"
  git -C "$seed" add gamma-local.txt
  git -C "$seed" commit -m "gamma local commit" --quiet
  git -C "$seed" push --quiet "$base/local/gamma.git" gamma-local:main

  git -C "$seed" checkout main --quiet
  git -C "$seed" checkout -b gamma-peer --quiet
  echo "gamma-peer" > "$seed/gamma-peer.txt"
  git -C "$seed" add gamma-peer.txt
  git -C "$seed" commit -m "gamma peer commit" --quiet
  git -C "$seed" push --quiet "$base/peer/gamma.git" gamma-peer:main

  # delta: local-only repo.
  git -C "$seed" checkout main --quiet
  git -C "$seed" checkout -b delta-only --quiet
  echo "delta-only" > "$seed/delta.txt"
  git -C "$seed" add delta.txt
  git -C "$seed" commit -m "delta only" --quiet
  git -C "$seed" push --quiet "$base/local/delta.git" delta-only:main

  # Add a tag on local gamma that is missing from peer gamma.
  git -C "$seed" checkout gamma-local --quiet
  git -C "$seed" tag local-tag-v1
  git -C "$seed" push --quiet "$base/local/gamma.git" local-tag-v1

  echo "$base"
}


setup() {
  LOCAL_SERVER_PID=""
  mkfixture_certs
  setup_trust_dirs
  start_server
}

teardown() {
  if [[ -n "${LOCAL_SERVER_PID:-}" ]]; then
    kill "$LOCAL_SERVER_PID" 2>/dev/null || true
    wait "$LOCAL_SERVER_PID" 2>/dev/null || true
    LOCAL_SERVER_PID=""
  fi
  stop_server
  rm -rf "$TRUST_BASE_DIR" 2>/dev/null || true
  TRUST_DIR=""
  PURGATORY_DIR=""
  TRUST_BASE_DIR=""
}

@test "rejects clients without a certificate" {
  run curl -sS --max-time 5 --cacert "$SERVER_CERT" \
    "https://localhost:$MTLS_PORT/nope"
  [ "$status" -ne 0 ]
}

@test "rejects client certs not in trust store" {
  local tmp
  tmp="$(mktemp -d)"
  openssl req -x509 -newkey rsa:2048 -nodes -days 1 \
    -keyout "$tmp/evil.key" -out "$tmp/evil.crt" -subj "/CN=evil" >/dev/null 2>&1
  run curl -sS --fail --max-time 5 --cacert "$SERVER_CERT" \
    --cert "$tmp/evil.crt" --key "$tmp/evil.key" \
    "https://localhost:$MTLS_PORT/evil" 2>/dev/null
  rm -rf "$tmp"
  [ "$status" -ne 0 ]
}

@test "echoes the path segment as text/plain for authenticated clients" {
  run curl -sS --fail --max-time 5 \
    --cacert "$SERVER_CERT" \
    --cert "$CLIENT_CERT" --key "$CLIENT_KEY" \
    "https://localhost:$MTLS_PORT/hello%20world"
  [ "$status" -eq 0 ]
  [ "$output" = "hello world" ]
}

@test "serves a text/plain content type" {
  run curl -sS --fail --max-time 5 -D - -o /dev/null \
    --cacert "$SERVER_CERT" \
    --cert "$CLIENT_CERT" --key "$CLIENT_KEY" \
    "https://localhost:$MTLS_PORT/foo"
  [ "$status" -eq 0 ]
  echo "$output" | grep -qi "content-type: text/plain"
}

@test "discovers peer instances on a multicast-capable network" {
  if ! ip link show lo | grep -q '<.*MULTICAST.*>'; then
    skip "loopback interface lacks MULTICAST flag; discovery requires a LAN interface"
  fi

  local log1 log2 pid1 pid2
  log1="/tmp/mtls-peer1-$$.log"
  log2="/tmp/mtls-peer2-$$.log"

  # Start a second server on a different port in the background.
  
  ./mtls-hello 18444 \
    "$SERVER_CERT" "$SERVER_KEY" "$SERVER_CERT" \
    >"$log2" 2>&1 &
  pid2=$!

  # Wait for the second server to be ready.
  local _i
  for _i in $(seq 1 100); do
    if (exec 5<>"/dev/tcp/127.0.0.1/18444") 2>/dev/null; then
      exec 5>&- 5<&- 2>/dev/null || true
      break
    fi
    sleep 0.1
  done

  # Both servers now announce every 5 seconds; wait for at least one exchange.
  sleep 7

  run grep -E "peer at .*on port (18443|18444)" /tmp/mtls-server-$$.log
  [ "$status" -eq 0 ]
  run grep -E "peer at .*on port (18443|18444)" "$log2"
  [ "$status" -eq 0 ]

  kill "$pid2" 2>/dev/null || true
  wait "$pid2" 2>/dev/null || true
}

@test "supports --no-multicast to disable discovery" {
  teardown
  start_server "$MTLS_PORT" --no-multicast

  run grep -E "multicast discovery|\\[discovery\\]" /tmp/mtls-server-$$.log
  [ "$status" -ne 0 ]

  # HTTP still works when discovery is disabled.
  run curl -sS --fail --max-time 5 \
    --cacert "$SERVER_CERT" \
    --cert "$CLIENT_CERT" --key "$CLIENT_KEY" \
    "https://localhost:$MTLS_PORT/ping"
  [ "$status" -eq 0 ]
  [ "$output" = "ping" ]
}

@test "supports a custom listen port" {
  teardown
  start_server 19443

  run curl -sS --fail --max-time 5 \
    --cacert "$SERVER_CERT" \
    --cert "$CLIENT_CERT" --key "$CLIENT_KEY" \
    "https://localhost:19443/custom-port"
  [ "$status" -eq 0 ]
  [ "$output" = "custom-port" ]
}

@test "executes a GET handler and exposes query params" {
  local handlers
  handlers="$(mktemp -d)"
  printf '#!/bin/bash\necho "repo=$QUERY_REPO method=$REQUEST_METHOD script=$SCRIPT_NAME"\n' > "$handlers/echo.get.sh"
  chmod +x "$handlers/echo.get.sh"

  teardown
  start_server "$MTLS_PORT" --handlers-dir "$handlers"

  run curl -sS --fail --max-time 5 \
    --cacert "$SERVER_CERT" \
    --cert "$CLIENT_CERT" --key "$CLIENT_KEY" \
    "https://localhost:$MTLS_PORT/echo?repo=alpha"
  [ "$status" -eq 0 ]
  [ "$output" = "repo=alpha method=GET script=echo" ]

  rm -rf "$handlers"
}

@test "executes a POST handler and passes the request body on stdin" {
  local handlers
  handlers="$(mktemp -d)"
  printf '#!/bin/bash\ncat\n' > "$handlers/cat.post.sh"
  chmod +x "$handlers/cat.post.sh"

  teardown
  start_server "$MTLS_PORT" --handlers-dir "$handlers"

  run curl -sS --fail --max-time 5 \
    --cacert "$SERVER_CERT" \
    --cert "$CLIENT_CERT" --key "$CLIENT_KEY" \
    --data "hello body" \
    "https://localhost:$MTLS_PORT/cat"
  [ "$status" -eq 0 ]
  [ "$output" = "hello body" ]

  rm -rf "$handlers"
}

@test "GET falls back to echo when no handler matches" {
  run curl -sS --fail --max-time 5 \
    --cacert "$SERVER_CERT" \
    --cert "$CLIENT_CERT" --key "$CLIENT_KEY" \
    "https://localhost:$MTLS_PORT/fallback"
  [ "$status" -eq 0 ]
  [ "$output" = "fallback" ]
}

@test "POST returns 404 when no handler matches" {
  run curl -sS --fail --max-time 5 \
    --cacert "$SERVER_CERT" \
    --cert "$CLIENT_CERT" --key "$CLIENT_KEY" \
    --data "x" \
    "https://localhost:$MTLS_PORT/no-such-handler"
  [ "$status" -ne 0 ]
}

@test "rejects handler names containing dots or slashes with 400" {
  run curl -sS --fail --max-time 5 \
    --cacert "$SERVER_CERT" \
    --cert "$CLIENT_CERT" --key "$CLIENT_KEY" \
    "https://localhost:$MTLS_PORT/foo.bar"
  [ "$status" -ne 0 ]

  run curl -sS --fail --max-time 5 \
    --cacert "$SERVER_CERT" \
    --cert "$CLIENT_CERT" --key "$CLIENT_KEY" \
    "https://localhost:$MTLS_PORT/foo/bar"
  [ "$status" -ne 0 ]
}

@test "returns 500 when a handler exits non-zero" {
  local handlers
  handlers="$(mktemp -d)"
  printf '#!/bin/bash\necho "partial"\nexit 1\n' > "$handlers/fail.get.sh"
  chmod +x "$handlers/fail.get.sh"

  teardown
  start_server "$MTLS_PORT" --handlers-dir "$handlers"

  run curl -sS --fail --max-time 5 \
    --cacert "$SERVER_CERT" \
    --cert "$CLIENT_CERT" --key "$CLIENT_KEY" \
    "https://localhost:$MTLS_PORT/fail" 2>/dev/null
  [ "$status" -ne 0 ]

  rm -rf "$handlers"
}

mkfixture_bare_symlinked() {
  local base="$1"
  rm -rf "$base"
  mkdir -p "$base"
  mkfixture_bare "$base/real" >/dev/null
  mkdir -p "$base/local" "$base/peer"
  local name
  for name in alpha beta gamma delta; do
    ln -s "../real/local/${name}.git" "$base/local/${name}.git"
    ln -s "../real/peer/${name}.git" "$base/peer/${name}.git"
  done
  echo "$base"
}

@test "US1: bare-repo sync — all branches, tags, and diverged branches" {
  local fixture port
  fixture="$(mkfixture_bare "/tmp/mtls-bare-demo-$$")"
  port=18530

  teardown
  REPOS_ROOT="$fixture/peer" start_server "$port" --handlers-dir handlers

  HOST_NAME=local \
  PEER_NETLOC="localhost:$port" \
  PEER_CERT_FILE="$SERVER_CERT" \
  OUR_CERT="$CLIENT_CERT" \
  OUR_KEY="$CLIENT_KEY" \
  REPOS_ROOT="$fixture/local" \
    run bash scripts/on-discover.sh
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "synced="
  echo "$output" | grep -q "skipped="

  teardown
  REPOS_ROOT="$fixture/local" start_server "$port" --handlers-dir handlers

  HOST_NAME=peer \
  PEER_NETLOC="localhost:$port" \
  PEER_CERT_FILE="$SERVER_CERT" \
  OUR_CERT="$CLIENT_CERT" \
  OUR_KEY="$CLIENT_KEY" \
  REPOS_ROOT="$fixture/peer" \
    run bash scripts/on-discover.sh
  [ "$status" -eq 0 ]

  # alpha: local ahead → both sides fast-forwarded to local HEAD.
  [ "$(git -C "$fixture/local/alpha.git" rev-parse refs/heads/main)" = "$(git -C "$fixture/peer/alpha.git" rev-parse refs/heads/main)" ]

  # beta: peer ahead → both sides fast-forwarded to peer HEAD.
  [ "$(git -C "$fixture/local/beta.git" rev-parse refs/heads/main)" = "$(git -C "$fixture/peer/beta.git" rev-parse refs/heads/main)" ]

  # gamma: diverged → both versions preserved.
  [ "$(git -C "$fixture/local/gamma.git" rev-parse refs/heads/main)" != "$(git -C "$fixture/local/gamma.git" rev-parse refs/remotes/peer/main)" ]
  [ "$(git -C "$fixture/peer/gamma.git" rev-parse refs/heads/main)" != "$(git -C "$fixture/peer/gamma.git" rev-parse refs/remotes/local/main)" ]

  # delta: local-only → peer created the same branch.
  [ "$(git -C "$fixture/local/delta.git" rev-parse refs/heads/main)" = "$(git -C "$fixture/peer/delta.git" rev-parse refs/heads/main)" ]

  # tag: local-tag-v1 pushed to peer gamma.
  git -C "$fixture/peer/gamma.git" show-ref --verify --quiet refs/tags/local-tag-v1

  # Verify cloning from bare repos works — should see branches and recover content.
  local clone
  clone="$(mktemp -d)"
  git clone "$fixture/local/alpha.git" "$clone/alpha" 2>/dev/null
  [ -d "$clone/alpha" ]
  [ "$(git -C "$clone/alpha" rev-parse HEAD)" = "$(git -C "$fixture/local/alpha.git" rev-parse refs/heads/main)" ]
  grep -q "alpha-local" "$clone/alpha/alpha.txt" 2>/dev/null
  rm -rf "$clone"

  rm -rf "$fixture"
}

@test "US1: bare-repo sync works with fully symlinked REPOS_ROOT" {
  local fixture port
  fixture="$(mkfixture_bare_symlinked "/tmp/mtls-bare-symlink-demo-$$")"
  port=18540

  teardown
  REPOS_ROOT="$fixture/peer" start_server "$port" --handlers-dir handlers

  HOST_NAME=local \
  PEER_NETLOC="localhost:$port" \
  PEER_CERT_FILE="$SERVER_CERT" \
  OUR_CERT="$CLIENT_CERT" \
  OUR_KEY="$CLIENT_KEY" \
  REPOS_ROOT="$fixture/local" \
    run bash scripts/on-discover.sh
  [ "$status" -eq 0 ]

  teardown
  REPOS_ROOT="$fixture/local" start_server "$port" --handlers-dir handlers

  HOST_NAME=peer \
  PEER_NETLOC="localhost:$port" \
  PEER_CERT_FILE="$SERVER_CERT" \
  OUR_CERT="$CLIENT_CERT" \
  OUR_KEY="$CLIENT_KEY" \
  REPOS_ROOT="$fixture/peer" \
    run bash scripts/on-discover.sh
  [ "$status" -eq 0 ]

  # Same invariants as the real-directory test.
  [ "$(git -C "$fixture/local/alpha.git" rev-parse refs/heads/main)" = "$(git -C "$fixture/peer/alpha.git" rev-parse refs/heads/main)" ]
  [ "$(git -C "$fixture/local/beta.git" rev-parse refs/heads/main)" = "$(git -C "$fixture/peer/beta.git" rev-parse refs/heads/main)" ]
  [ "$(git -C "$fixture/local/gamma.git" rev-parse refs/heads/main)" != "$(git -C "$fixture/local/gamma.git" rev-parse refs/remotes/peer/main)" ]
  git -C "$fixture/peer/gamma.git" show-ref --verify --quiet refs/tags/local-tag-v1

  rm -rf "$fixture"
}

@test "US2: broken symlink under REPOS_ROOT fails cleanly" {
  local fixture port
  fixture="$(mkfixture_bare_symlinked "/tmp/mtls-bare-broken-demo-$$")"
  port=18550

  # Break the peer beta entry.
  rm "$fixture/peer/beta.git"
  ln -s /nonexistent-target "$fixture/peer/beta.git"

  teardown
  REPOS_ROOT="$fixture/peer" start_server "$port" --handlers-dir handlers

  HOST_NAME=local \
  PEER_NETLOC="localhost:$port" \
  PEER_CERT_FILE="$SERVER_CERT" \
  OUR_CERT="$CLIENT_CERT" \
  OUR_KEY="$CLIENT_KEY" \
  REPOS_ROOT="$fixture/local" \
    run bash scripts/on-discover.sh
  [ "$status" -eq 0 ]

  # The broken peer beta causes the push to fail; it must not be synced.
  echo "$output" | grep -q "push failed"
  echo "$output" | grep -q "skipped="

  # alpha (healthy) still synced.
  [ "$(git -C "$fixture/local/alpha.git" rev-parse refs/heads/main)" = "$(git -C "$fixture/peer/alpha.git" rev-parse refs/heads/main)" ]

  # beta on peer is still broken.
  ! git -C "$fixture/peer/beta.git" rev-parse refs/heads/main >/dev/null 2>&1

  rm -rf "$fixture"
}

@test "US2: repeated bare-repo sync is idempotent" {
  local fixture port
  fixture="$(mkfixture_bare "/tmp/mtls-bare-idempotent-demo-$$")"
  port=18560

  teardown
  REPOS_ROOT="$fixture/peer" start_server "$port" --handlers-dir handlers

  HOST_NAME=local \
  PEER_NETLOC="localhost:$port" \
  PEER_CERT_FILE="$SERVER_CERT" \
  OUR_CERT="$CLIENT_CERT" \
  OUR_KEY="$CLIENT_KEY" \
  REPOS_ROOT="$fixture/local" \
    run bash scripts/on-discover.sh
  [ "$status" -eq 0 ]

  teardown
  REPOS_ROOT="$fixture/local" start_server "$port" --handlers-dir handlers

  HOST_NAME=peer \
  PEER_NETLOC="localhost:$port" \
  PEER_CERT_FILE="$SERVER_CERT" \
  OUR_CERT="$CLIENT_CERT" \
  OUR_KEY="$CLIENT_KEY" \
  REPOS_ROOT="$fixture/peer" \
    run bash scripts/on-discover.sh
  [ "$status" -eq 0 ]

  local local_alpha_main peer_alpha_main
  local_alpha_main="$(git -C "$fixture/local/alpha.git" rev-parse refs/heads/main)"
  peer_alpha_main="$(git -C "$fixture/peer/alpha.git" rev-parse refs/heads/main)"

  teardown
  REPOS_ROOT="$fixture/peer" start_server "$port" --handlers-dir handlers

  HOST_NAME=local \
  PEER_NETLOC="localhost:$port" \
  PEER_CERT_FILE="$SERVER_CERT" \
  OUR_CERT="$CLIENT_CERT" \
  OUR_KEY="$CLIENT_KEY" \
  REPOS_ROOT="$fixture/local" \
    run bash scripts/on-discover.sh
  [ "$status" -eq 0 ]

  teardown
  REPOS_ROOT="$fixture/local" start_server "$port" --handlers-dir handlers

  HOST_NAME=peer \
  PEER_NETLOC="localhost:$port" \
  PEER_CERT_FILE="$SERVER_CERT" \
  OUR_CERT="$CLIENT_CERT" \
  OUR_KEY="$CLIENT_KEY" \
  REPOS_ROOT="$fixture/peer" \
    run bash scripts/on-discover.sh
  [ "$status" -eq 0 ]

  [ "$local_alpha_main" = "$(git -C "$fixture/local/alpha.git" rev-parse refs/heads/main)" ]
  [ "$peer_alpha_main" = "$(git -C "$fixture/peer/alpha.git" rev-parse refs/heads/main)" ]

  rm -rf "$fixture"
}

@test "US1: trusted peer with matching certificate is accepted" {
  run curl -sS --fail --max-time 5 \
    --cacert "$SERVER_CERT" \
    --cert "$CLIENT_CERT" --key "$CLIENT_KEY" \
    "https://localhost:$MTLS_PORT/hello"
  [ "$status" -eq 0 ]
  [ "$output" = "hello" ]
}

@test "US1: unknown peer is rejected and captured in purgatory" {
  local tmp
  tmp="$(mktemp -d)"
  openssl req -x509 -newkey rsa:2048 -nodes -days 1 \
    -keyout "$tmp/evil.key" -out "$tmp/evil.crt" -subj "/CN=evil" >/dev/null 2>&1

  run curl -sS --fail --max-time 5 \
    --cacert "$SERVER_CERT" \
    --cert "$tmp/evil.crt" --key "$tmp/evil.key" \
    "https://localhost:$MTLS_PORT/hello" 2>/dev/null
  [ "$status" -ne 0 ]

  # Exactly one purgatory entry for the evil hostname.
  [ -f "$PURGATORY_DIR/evil."*.crt ]

  rm -rf "$tmp"
}

@test "US1: mismatched certificate for trusted hostname is rejected" {
  local tmp
  tmp="$(mktemp -d)"
  openssl req -x509 -newkey rsa:2048 -nodes -days 1 \
    -keyout "$tmp/other.key" -out "$tmp/other.crt" -subj "/CN=test-client" >/dev/null 2>&1

  run curl -sS --fail --max-time 5 \
    --cacert "$SERVER_CERT" \
    --cert "$tmp/other.crt" --key "$tmp/other.key" \
    "https://localhost:$MTLS_PORT/hello" 2>/dev/null
  [ "$status" -ne 0 ]

  [ -f "$PURGATORY_DIR/test-client."*.crt ]

  rm -rf "$tmp"
}

@test "US2: repeated unknown certificate does not duplicate purgatory entries" {
  local tmp
  tmp="$(mktemp -d)"
  openssl req -x509 -newkey rsa:2048 -nodes -days 1 \
    -keyout "$tmp/evil.key" -out "$tmp/evil.crt" -subj "/CN=evil" >/dev/null 2>&1

  curl -sS --fail --max-time 5 \
    --cacert "$SERVER_CERT" \
    --cert "$tmp/evil.crt" --key "$tmp/evil.key" \
    "https://localhost:$MTLS_PORT/hello" 2>/dev/null || true

  curl -sS --fail --max-time 5 \
    --cacert "$SERVER_CERT" \
    --cert "$tmp/evil.crt" --key "$tmp/evil.key" \
    "https://localhost:$MTLS_PORT/hello" 2>/dev/null || true

  [ "$(ls -1 "$PURGATORY_DIR" | wc -l)" -eq 1 ]

  rm -rf "$tmp"
}

@test "US2: purgatory certificate does not grant trust" {
  local tmp
  tmp="$(mktemp -d)"
  openssl req -x509 -newkey rsa:2048 -nodes -days 1 \
    -keyout "$tmp/evil.key" -out "$tmp/evil.crt" -subj "/CN=evil" >/dev/null 2>&1

  curl -sS --fail --max-time 5 \
    --cacert "$SERVER_CERT" \
    --cert "$tmp/evil.crt" --key "$tmp/evil.key" \
    "https://localhost:$MTLS_PORT/hello" 2>/dev/null || true

  run curl -sS --fail --max-time 5 \
    --cacert "$SERVER_CERT" \
    --cert "$tmp/evil.crt" --key "$tmp/evil.key" \
    "https://localhost:$MTLS_PORT/hello" 2>/dev/null
  [ "$status" -ne 0 ]

  rm -rf "$tmp"
}

@test "US3: onboarding flow promotes a fresh certificate to trusted" {
  local tmp
  tmp="$(mktemp -d)"
  openssl req -x509 -newkey rsa:2048 -nodes -days 1 \
    -keyout "$tmp/peer.key" -out "$tmp/peer.crt" -subj "/CN=peer.local" >/dev/null 2>&1

  run curl -sS --fail --max-time 5 \
    --cacert "$SERVER_CERT" \
    --cert "$tmp/peer.crt" --key "$tmp/peer.key" \
    "https://localhost:$MTLS_PORT/hello" 2>/dev/null
  [ "$status" -ne 0 ]

  run bash scripts/trust-host.sh peer.local "$tmp/peer.crt" "$TRUST_DIR"
  [ "$status" -eq 0 ]

  run curl -sS --fail --max-time 5 \
    --cacert "$SERVER_CERT" \
    --cert "$tmp/peer.crt" --key "$tmp/peer.key" \
    "https://localhost:$MTLS_PORT/hello"
  [ "$status" -eq 0 ]
  [ "$output" = "hello" ]

  rm -rf "$tmp"
}

@test "US1: just install copies binary and handlers to ~/.local" {

  command -v guix >/dev/null || skip "Guix dev environment not available (CI uses Docker)"
  local home_dir
  home_dir="$(mktemp -d)"

  export HOME="$home_dir"
  LD_LIBRARY_PATH="" run just install
  [ "$status" -eq 0 ]

  [ -x "$home_dir/.local/bin/mtls-hello" ]
  [ -f "$home_dir/.local/share/mtls-hello/handlers/bundle.post.sh" ]
  [ -x "$home_dir/.local/share/mtls-hello/scripts/on-discover.sh" ]
  [ -f "$home_dir/.local/share/mtls-hello/scripts/pre-push.sh.new" ]
  [ -f "$home_dir/.local/lib/mtls-hello/libssl.so.3" ]

  run "$home_dir/.local/bin/mtls-hello" --version
  [ "$status" -eq 0 ]
  [ -n "$output" ]

  rm -rf "$home_dir"
}

@test "US1: just install is idempotent" {

  command -v guix >/dev/null || skip "Guix dev environment not available (CI uses Docker)"
  local home_dir
  home_dir="$(mktemp -d)"

  export HOME="$home_dir"
  LD_LIBRARY_PATH="" run just install
  [ "$status" -eq 0 ]

  LD_LIBRARY_PATH="" run just install
  [ "$status" -eq 0 ]

  [ -x "$home_dir/.local/bin/mtls-hello" ]
  [ -f "$home_dir/.local/share/mtls-hello/handlers/bundle.post.sh" ]

  rm -rf "$home_dir"
}

@test "US1: just install creates missing ~/.local directories" {

  command -v guix >/dev/null || skip "Guix dev environment not available (CI uses Docker)"
  local home_dir
  home_dir="$(mktemp -d)"
  rm -rf "$home_dir/.local"

  export HOME="$home_dir"
  LD_LIBRARY_PATH="" run just install
  [ "$status" -eq 0 ]

  [ -d "$home_dir/.local/bin" ]
  [ -d "$home_dir/.local/share/mtls-hello/handlers" ]

  rm -rf "$home_dir"
}

@test "US1: just install generates self-signed server cert" {

  command -v guix >/dev/null || skip "Guix dev environment not available (CI uses Docker)"
  local home_dir
  home_dir="$(mktemp -d)"

  export HOME="$home_dir"
  LD_LIBRARY_PATH="" run just install
  [ "$status" -eq 0 ]

  [ -f "$home_dir/.local/share/mtls-hello/certs/certs/server.crt" ]
  [ -f "$home_dir/.local/share/mtls-hello/certs/private/server.key" ]

  local subject
  subject="$(openssl x509 -in "$home_dir/.local/share/mtls-hello/certs/certs/server.crt" -noout -subject)"
  [[ "$subject" == *"CN = $(hostname)"* ]]

  local mode
  mode="$(stat -c %a "$home_dir/.local/share/mtls-hello/certs/private/server.key")"
  [ "$mode" = "600" ]

  rm -rf "$home_dir"
}

@test "US1: just install does not overwrite existing certs" {

  command -v guix >/dev/null || skip "Guix dev environment not available (CI uses Docker)"
  local home_dir
  home_dir="$(mktemp -d)"
  mkdir -p "$home_dir/.local/share/mtls-hello/certs/certs" \
           "$home_dir/.local/share/mtls-hello/certs/private"
  openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
    -keyout "$home_dir/.local/share/mtls-hello/certs/private/server.key" \
    -out "$home_dir/.local/share/mtls-hello/certs/certs/server.crt" \
    -subj "/CN=existing" >/dev/null 2>&1
  chmod 600 "$home_dir/.local/share/mtls-hello/certs/private/server.key"
  local fingerprint
  fingerprint="$(openssl x509 -in "$home_dir/.local/share/mtls-hello/certs/certs/server.crt" -noout -fingerprint -sha256)"

  export HOME="$home_dir"
  LD_LIBRARY_PATH="" run just install
  [ "$status" -eq 0 ]

  local after
  after="$(openssl x509 -in "$home_dir/.local/share/mtls-hello/certs/certs/server.crt" -noout -fingerprint -sha256)"
  [ "$fingerprint" = "$after" ]

  rm -rf "$home_dir"
}

@test "US1: just install warns and skips when openssl is missing" {

  command -v guix >/dev/null || skip "Guix dev environment not available (CI uses Docker)"
  local home_dir fake_bin
  home_dir="$(mktemp -d)"
  fake_bin="$(mktemp -d)"
  rm -rf "$home_dir/.local"

  # Create a fake openssl that is found on PATH but fails to run.
  printf '#!/bin/bash\necho "openssl: command not found" >&2\nexit 1\n' > "$fake_bin/openssl"
  chmod +x "$fake_bin/openssl"

  export HOME="$home_dir"
  # Prepend fake bin to PATH so install.sh finds the broken openssl.
  run env PATH="$fake_bin:$PATH" LD_LIBRARY_PATH="" bash scripts/install.sh
  [ "$status" -eq 0 ]

  [ ! -f "$home_dir/.local/share/mtls-hello/certs/certs/server.crt" ]
  echo "$output" | grep -qi "openssl not found"

  rm -rf "$home_dir" "$fake_bin"
}

@test "US2: --port=0 picks a random port" {
  local port_file log
  port_file="/tmp/mtls-port-$$-test"
  log="/tmp/mtls-server-$$-random.log"
  rm -f "$port_file"

  ./mtls-hello 0 "$SERVER_CERT" "$SERVER_KEY" \
    --no-multicast --trust-dir "$TRUST_DIR" --purgatory-dir "$PURGATORY_DIR" \
    --port-file="$port_file" > "$log" 2>&1 &
  LOCAL_SERVER_PID=$!

  local port
  for _i in $(seq 1 100); do
    [ -s "$port_file" ] && break
    sleep 0.1
  done
  [ -s "$port_file" ]
  port="$(cat "$port_file")"
  [ "$port" -ne 0 ]
  [ "$port" -ne 8443 ]
  grep -q ":$port" "$log"

  run curl -sS --fail --max-time 5 \n    --cacert "$SERVER_CERT" \
    --cert "$CLIENT_CERT" --key "$CLIENT_KEY" \
    "https://localhost:$port/hello"
  [ "$status" -eq 0 ]
  [ "$output" = "hello" ]

  rm -f "$port_file" "$log"
}

@test "US2: --port-file writes the port atomically" {
  local port_file log
  port_file="/tmp/mtls-port-$$-test"
  log="/tmp/mtls-server-$$-portfile.log"
  rm -f "$port_file"

  ./mtls-hello 0 "$SERVER_CERT" "$SERVER_KEY" \
    --no-multicast --trust-dir "$TRUST_DIR" --purgatory-dir "$PURGATORY_DIR" \
    --port-file="$port_file" > "$log" 2>&1 &
  LOCAL_SERVER_PID=$!

  local port
  for _i in $(seq 1 100); do
    [ -s "$port_file" ] && break
    sleep 0.1
  done
  [ -s "$port_file" ]
  port="$(cat "$port_file")"
  [ "$port" -gt 0 ]
  [ "$port" -le 65535 ]

  grep -q ":$port" "$log"

  run curl -sS --fail --max-time 5 \
    --cacert "$SERVER_CERT" \
    --cert "$CLIENT_CERT" --key "$CLIENT_KEY" \
    "https://localhost:$port/hello"
  [ "$status" -eq 0 ]
  [ "$output" = "hello" ]

  rm -f "$port_file" "$log"
}

@test "US2: port 8443 works with self-signed certs" {
  # Stop the global server started by setup() so we can bind the default port.
  stop_server

  local log
  log="/tmp/mtls-server-$$-default.log"

  ./mtls-hello 8443 \
    "$SERVER_CERT" "$SERVER_KEY" \
    --no-multicast --trust-dir "$TRUST_DIR" --purgatory-dir "$PURGATORY_DIR" \
    > "$log" 2>&1 &
  LOCAL_SERVER_PID=$!

  for _i in $(seq 1 100); do
    if (exec 5<>"/dev/tcp/127.0.0.1/8443") 2>/dev/null; then
      exec 5>&- 5<&- 2>/dev/null || true
      break
    fi
    sleep 0.1
  done

  run curl -sS --fail --max-time 5 \
    --cacert "$SERVER_CERT" \
    --cert "$CLIENT_CERT" --key "$CLIENT_KEY" \
    "https://localhost:8443/hello"
  [ "$status" -eq 0 ]
  [ "$output" = "hello" ]

  rm -f "$log"
}

@test "US3: just install-service creates a valid systemd user unit" {

  command -v guix >/dev/null || skip "Guix dev environment not available (CI uses Docker)"
  local home_dir
  home_dir="$(mktemp -d)"

  export HOME="$home_dir"
  export XDG_CONFIG_HOME="$home_dir/.config"

  LD_LIBRARY_PATH="" run just install
  [ "$status" -eq 0 ]

  LD_LIBRARY_PATH="" run just install-service
  [ "$status" -eq 0 ]

  [ -f "$home_dir/.config/systemd/user/mtls-hello.service" ]
  grep -q "LD_LIBRARY_PATH=%h/.local/lib/mtls-hello" "$home_dir/.config/systemd/user/mtls-hello.service"
  grep -q "data-dir=%h/.local/share/mtls-hello" "$home_dir/.config/systemd/user/mtls-hello.service"
  ! grep -q "handlers-dir" "$home_dir/.config/systemd/user/mtls-hello.service"
  ! grep -q "guix" "$home_dir/.config/systemd/user/mtls-hello.service"
  grep -q "Restart=on-failure" "$home_dir/.config/systemd/user/mtls-hello.service"

  if command -v systemd-analyze >/dev/null 2>&1; then
    LD_LIBRARY_PATH="" run systemd-analyze --user verify "$home_dir/.config/systemd/user/mtls-hello.service"
    [ "$status" -eq 0 ]
  fi

  rm -rf "$home_dir"
}

@test "US3: just install-service refuses without prior install" {

  command -v guix >/dev/null || skip "Guix dev environment not available (CI uses Docker)"
  local home_dir
  home_dir="$(mktemp -d)"

  export HOME="$home_dir"
  export XDG_CONFIG_HOME="$home_dir/.config"

  LD_LIBRARY_PATH="" run just install-service
  [ "$status" -ne 0 ]
  [[ "$output" == *"not found"* ]]

  rm -rf "$home_dir"
}

@test "callback spawn is non-blocking" {
  local marker callback
  marker="$(mktemp -d)"
  callback="$marker/callback.sh"
  printf '#!/bin/bash\nsleep 1\necho "$PEER_NETLOC" >> "%s/markers"\n' "$marker" > "$callback"
  chmod +x "$callback"

  teardown
  CALLBACK_SCRIPT="$callback" start_server "$MTLS_PORT"

  printf '{"service":"mtls-hello","port":9998,"host":"peer1"}\n' >/dev/udp/127.0.0.1/4242
  printf '{"service":"mtls-hello","port":9999,"host":"peer2"}\n' >/dev/udp/127.0.0.1/4242

  local _i
  for _i in $(seq 1 50); do
    [ "$(wc -l < "$marker/markers" 2>/dev/null || echo 0)" -eq 2 ] && break
    sleep 0.2
  done
  [ "$(wc -l < "$marker/markers")" -eq 2 ]

  rm -rf "$marker"
}

@test "missing callback script logs warning and continues" {
  teardown
  CALLBACK_SCRIPT="/nonexistent/callback.sh" start_server "$MTLS_PORT"

  printf '{"service":"mtls-hello","port":9999,"host":"peer"}\n' >/dev/udp/127.0.0.1/4242

  sleep 1
  grep -q "multicast warning: failed to spawn callback" /tmp/mtls-server-$$.log
}

@test "multicast announcement includes host field" {
  teardown
  HOST_NAME=testme start_server "$MTLS_PORT"

  # The server sends its first announcement immediately after startup.
  sleep 2
  grep -q '"host":"testme"' /tmp/mtls-server-$$.log || { cat /tmp/mtls-server-$$.log; false; }
}

@test "multicast announcement host defaults to localhost" {
  teardown
  start_server "$MTLS_PORT"

  sleep 2
  grep -qE '"host":"[^"]+"' /tmp/mtls-server-$$.log || { cat /tmp/mtls-server-$$.log; false; }
}

@test "discovered peer triggers on-discover callback" {
  local marker callback
  marker="$(mktemp -d)"
  callback="$marker/callback.sh"
  printf '#!/bin/bash\necho "$PEER_NETLOC $PEER_CERT_FILE" > "%s/marker"\n' "$marker" > "$callback"
  chmod +x "$callback"

  teardown
  CALLBACK_SCRIPT="$callback" \
  HOST_NAME=local \
  OUR_CERT="$CLIENT_CERT" \
  OUR_KEY="$CLIENT_KEY" \
  REPOS_ROOT=/tmp \
    start_server "$MTLS_PORT"

  printf '{"service":"mtls-hello","port":9999,"host":"peer"}\n' >/dev/udp/127.0.0.1/4242

  local _i
  for _i in $(seq 1 50); do
    [ -f "$marker/marker" ] && break
    sleep 0.1
  done
  [ -f "$marker/marker" ] || { cat /tmp/mtls-server-$$.log; false; }
  grep -q "127.0.0.1:9999" "$marker/marker"
  grep -q "$TRUST_DIR/peer.crt" "$marker/marker"

  rm -rf "$marker"
}

@test "own announcement does not trigger callback" {
  local marker callback
  marker="$(mktemp -d)"
  callback="$marker/callback.sh"
  printf '#!/bin/bash\necho "spawned" > "%s/marker"\n' "$marker" > "$callback"
  chmod +x "$callback"

  teardown
  CALLBACK_SCRIPT="$callback" start_server "$MTLS_PORT"

  # Send an announcement that looks like our own.
  printf '{"service":"mtls-hello","port":%s,"host":"local"}\n' "$MTLS_PORT" >/dev/udp/127.0.0.1/4242

  sleep 2
  [ ! -f "$marker/marker" ]

  rm -rf "$marker"
}

@test "data-dir derives handlers path" {
  local data_dir="$(mktemp -d)"
  mkdir -p "$data_dir/handlers"
  printf '#!/bin/bash\necho "from-data-dir"\n' > "$data_dir/handlers/hello.get.sh"
  chmod +x "$data_dir/handlers/hello.get.sh"

  teardown
  start_server "$MTLS_PORT" --data-dir="$data_dir"

  run curl -sS --fail --max-time 5 \
    --cacert "$SERVER_CERT" \
    --cert "$CLIENT_CERT" --key "$CLIENT_KEY" \
    "https://localhost:$MTLS_PORT/hello"
  [ "$status" -eq 0 ]
  [ "$output" = "from-data-dir" ]

  rm -rf "$data_dir"
}

@test "data-dir derives callback path" {
  local data_dir="$(mktemp -d)"
  mkdir -p "$data_dir/scripts"
  printf '#!/bin/bash\necho "$PEER_NETLOC" > "%s/marker"\n' "$data_dir" > "$data_dir/scripts/on-discover.sh"
  chmod +x "$data_dir/scripts/on-discover.sh"

  teardown
  start_server "$MTLS_PORT" --data-dir="$data_dir"

  printf '{"service":"mtls-hello","port":9999,"host":"peer"}\n' >/dev/udp/127.0.0.1/4242

  local _i
  for _i in $(seq 1 50); do
    [ -f "$data_dir/marker" ] && break
    sleep 0.1
  done
  [ -f "$data_dir/marker" ]
  grep -q "127.0.0.1:9999" "$data_dir/marker"

  rm -rf "$data_dir"
}

@test "explicit --handlers-dir overrides data-dir" {
  local data_dir="$(mktemp -d)"
  local custom="$(mktemp -d)"
  mkdir -p "$data_dir/handlers"
  printf '#!/bin/bash\necho "from-data-dir"\n' > "$data_dir/handlers/hello.get.sh"
  chmod +x "$data_dir/handlers/hello.get.sh"
  printf '#!/bin/bash\necho "from-custom"\n' > "$custom/hello.get.sh"
  chmod +x "$custom/hello.get.sh"

  teardown
  start_server "$MTLS_PORT" --data-dir="$data_dir" --handlers-dir="$custom"

  run curl -sS --fail --max-time 5 \
    --cacert "$SERVER_CERT" \
    --cert "$CLIENT_CERT" --key "$CLIENT_KEY" \
    "https://localhost:$MTLS_PORT/hello"
  [ "$status" -eq 0 ]
  [ "$output" = "from-custom" ]

  rm -rf "$data_dir" "$custom"
}

@test "no --data-dir preserves existing defaults" {
  local handlers="$(mktemp -d)"
  printf '#!/bin/bash\necho "explicit-handlers"\n' > "$handlers/echo.get.sh"
  chmod +x "$handlers/echo.get.sh"

  teardown
  start_server "$MTLS_PORT" --handlers-dir="$handlers"

  run curl -sS --fail --max-time 5 \
    --cacert "$SERVER_CERT" \
    --cert "$CLIENT_CERT" --key "$CLIENT_KEY" \
    "https://localhost:$MTLS_PORT/echo"
  [ "$status" -eq 0 ]
  [ "$output" = "explicit-handlers" ]

  rm -rf "$handlers"
}

@test "US1: just self-extract produces a named script" {

  command -v guix >/dev/null || skip "Guix dev environment not available (CI uses Docker)"
  [ -n "$(get_self_extract_installer)" ]
  [ -f "$(get_self_extract_installer)" ]
  [ -x "$(get_self_extract_installer)" ]
  [[ "$(get_self_extract_installer)" =~ ^mtls-hello-installer-[0-9a-f]+-[0-9]{8}(-dirty)?\.sh$ ]]
}

@test "US1: just self-extract adds -dirty on unclean tree" {

  command -v guix >/dev/null || skip "Guix dev environment not available (CI uses Docker)"
  local dirty_file="$PWD/mtls-dirty-test.tmp"
  touch "$dirty_file"
  LD_LIBRARY_PATH="" run just self-extract
  [ "$status" -eq 0 ]
  local installer
  installer=$(ls -t mtls-hello-installer-*.sh | head -1)
  [[ "$installer" == *"-dirty.sh" ]]
  # Do not delete the installer here — filenames are deterministic and the
  # cached installer would disappear. teardown_file removes all installers.
  rm -f "$dirty_file"
}

@test "US1: self-extracting script --help prints usage" {

  command -v guix >/dev/null || skip "Guix dev environment not available (CI uses Docker)"
  run bash "$(get_self_extract_installer)" --help
  [ "$status" -eq 0 ]
  echo "$output" | grep -qi "install"
  echo "$output" | grep -qi "install-service"
}

@test "US2: installer install subcommand works" {

  command -v guix >/dev/null || skip "Guix dev environment not available (CI uses Docker)"
  local home_dir
  home_dir="$(mktemp -d)"

  export HOME="$home_dir"
  run env LD_LIBRARY_PATH="" PATH="/usr/bin:/bin" bash "$(get_self_extract_installer)" install
  [ "$status" -eq 0 ]

  [ -x "$home_dir/.local/bin/mtls-hello" ]
  [ -f "$home_dir/.local/lib/mtls-hello/libssl.so.3" ]
  [ -f "$home_dir/.local/share/mtls-hello/handlers/bundle.post.sh" ]
  [ -f "$home_dir/.local/share/mtls-hello/scripts/on-discover.sh" ]
  [ -f "$home_dir/.local/share/mtls-hello/scripts/pre-push.sh.new" ]
  [ -f "$home_dir/.local/share/mtls-hello/certs/certs/server.crt" ]
  [ -f "$home_dir/.local/share/mtls-hello/certs/private/server.key" ]

  local mode
  mode="$(stat -c %a "$home_dir/.local/share/mtls-hello/certs/private/server.key")"
  [ "$mode" = "600" ]

  run LD_LIBRARY_PATH="$home_dir/.local/lib/mtls-hello" "$home_dir/.local/bin/mtls-hello" --version
  [ "$status" -eq 0 ]
  [ -n "$output" ]

  rm -rf "$home_dir"
}

@test "US2: installer install does not overwrite existing certs" {

  command -v guix >/dev/null || skip "Guix dev environment not available (CI uses Docker)"
  local home_dir
  home_dir="$(mktemp -d)"
  mkdir -p "$home_dir/.local/share/mtls-hello/certs/certs" \
           "$home_dir/.local/share/mtls-hello/certs/private"
  openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
    -keyout "$home_dir/.local/share/mtls-hello/certs/private/server.key" \
    -out "$home_dir/.local/share/mtls-hello/certs/certs/server.crt" \
    -subj "/CN=existing" >/dev/null 2>&1
  chmod 600 "$home_dir/.local/share/mtls-hello/certs/private/server.key"
  local fingerprint
  fingerprint="$(openssl x509 -in "$home_dir/.local/share/mtls-hello/certs/certs/server.crt" -noout -fingerprint -sha256)"

  export HOME="$home_dir"
  run env LD_LIBRARY_PATH="" PATH="/usr/bin:/bin" bash "$(get_self_extract_installer)" install
  [ "$status" -eq 0 ]

  local after
  after="$(openssl x509 -in "$home_dir/.local/share/mtls-hello/certs/certs/server.crt" -noout -fingerprint -sha256)"
  [ "$fingerprint" = "$after" ]

  rm -rf "$home_dir"
}

@test "US2: installer install warns but succeeds without openssl" {

  command -v guix >/dev/null || skip "Guix dev environment not available (CI uses Docker)"
  local home_dir fake_bin
  home_dir="$(mktemp -d)"
  fake_bin="$(mktemp -d)"
  printf '#!/bin/bash\necho "openssl: command not found" >&2\nexit 1\n' > "$fake_bin/openssl"
  chmod +x "$fake_bin/openssl"

  export HOME="$home_dir"
  run env LD_LIBRARY_PATH="" PATH="$fake_bin:/usr/bin:/bin" bash "$(get_self_extract_installer)" install
  [ "$status" -eq 0 ]

  [ ! -f "$home_dir/.local/share/mtls-hello/certs/certs/server.crt" ]
  echo "$output" | grep -qi "openssl not found"

  rm -rf "$home_dir" "$fake_bin"
}

@test "US3: installer install-service creates a valid unit" {

  command -v guix >/dev/null || skip "Guix dev environment not available (CI uses Docker)"
  local home_dir
  home_dir="$(mktemp -d)"

  export HOME="$home_dir"
  export XDG_CONFIG_HOME="$home_dir/.config"
  run env LD_LIBRARY_PATH="" PATH="/usr/bin:/bin" bash "$(get_self_extract_installer)" install
  [ "$status" -eq 0 ]

  run env LD_LIBRARY_PATH="" PATH="/usr/bin:/bin" bash "$(get_self_extract_installer)" install-service
  [ "$status" -eq 0 ]

  [ -f "$home_dir/.config/systemd/user/mtls-hello.service" ]
  grep -q "LD_LIBRARY_PATH=%h/.local/lib/mtls-hello" "$home_dir/.config/systemd/user/mtls-hello.service"
  grep -q "data-dir=%h/.local/share/mtls-hello" "$home_dir/.config/systemd/user/mtls-hello.service"
  grep -q "--port=0" "$home_dir/.config/systemd/user/mtls-hello.service"

  if command -v systemd-analyze >/dev/null 2>&1; then
    run systemd-analyze --user verify "$home_dir/.config/systemd/user/mtls-hello.service"
    [ "$status" -eq 0 ]
  fi

  rm -rf "$home_dir"
}

@test "US3: installer install-service refuses without prior install" {

  command -v guix >/dev/null || skip "Guix dev environment not available (CI uses Docker)"
  local home_dir
  home_dir="$(mktemp -d)"

  export HOME="$home_dir"
  export XDG_CONFIG_HOME="$home_dir/.config"
  run env LD_LIBRARY_PATH="" PATH="/usr/bin:/bin" bash "$(get_self_extract_installer)" install-service
  [ "$status" -ne 0 ]
  [[ "$output" == *"not found"* ]]

  rm -rf "$home_dir"
}

@test "US3: package.sh detects debian via /etc/os-release" {
  local tmp
  tmp="$(mktemp -d)"
  printf 'ID=debian\nID_LIKE=debian\n' > "$tmp/os-release"
  OS_RELEASE_FILE="$tmp/os-release" run bash scripts/package.sh --detect
  [ "$status" -eq 0 ]
  [ "$output" = "debian" ]
  rm -rf "$tmp"
}

@test "US3: package.sh detects arch via /etc/os-release" {
  local tmp
  tmp="$(mktemp -d)"
  printf 'ID=arch\n' > "$tmp/os-release"
  OS_RELEASE_FILE="$tmp/os-release" run bash scripts/package.sh --detect
  [ "$status" -eq 0 ]
  [ "$output" = "arch" ]
  rm -rf "$tmp"
}

@test "US3: package.sh rejects unsupported distro" {
  local tmp
  tmp="$(mktemp -d)"
  printf 'ID=fedora\nID_LIKE=rhel\n' > "$tmp/os-release"
  OS_RELEASE_FILE="$tmp/os-release" run bash scripts/package.sh
  [ "$status" -ne 0 ]
  [[ "$output" == *"unsupported"* ]]
  [[ "$output" == *"package-docker"* ]]
  rm -rf "$tmp"
}
