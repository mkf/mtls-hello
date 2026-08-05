# Contract: Discovery Callback Script — Extended

**Branch**: `003-script-endpoints-git-sync` | **Date**: 2026-03-19 | **Feature**: [spec.md](../spec.md)

> This contract extends `specs/002-per-host-cert-hook/contracts/callback.md`. The invocation contract (env vars, execution model, exit-code handling) is unchanged. Additions: a POST-capable helper and a multi-repo synchronization example.

## Helper Function: mtls_curl_post

The callback script may define `mtls_curl_post` in addition to `mtls_curl` (GET).

### Signature

```bash
mtls_curl_post <path> <body-file>
```

### Example

```bash
mtls_curl_post "/bundle?repo=alpha" /tmp/alpha.bundle
# → POSTs the contents of /tmp/alpha.bundle to https://$PEER_NETLOC/bundle?repo=alpha
# → with mutual TLS using $OUR_CERT/$OUR_KEY (client) and $PEER_CERT_FILE (server verification)
```

### Semantics

- Issues an HTTP POST to `https://$PEER_NETLOC/<path>`.
- The request body is the full contents of `<body-file>`.
- Client authentication and server verification: identical to `mtls_curl` (certificate pinning via `$PEER_CERT_FILE`).
- Timeout: 30 seconds (bundle uploads may be larger than HEAD lookups).
- Exit code: 0 on success (HTTP 2xx), non-zero on failure.

### Reference Implementation

```bash
mtls_curl_post() {
  local path="$1" body_file="$2"
  curl -sS --fail --max-time 30 \
    --cacert "$PEER_CERT_FILE" \
    --cert "${OUR_CERT:-certs/certs/client.crt}" \
    --key "${OUR_KEY:-certs/private/client.key}" \
    --data-binary "@$body_file" \
    "https://$PEER_NETLOC/$path"
}
```

## Multi-Repo Synchronization Example

The default `scripts/on-discover.sh` demonstrates syncing multiple independent repositories: for each repo under `$REPOS_ROOT`, fetch the peer's HEAD via GET and, if the local side is ahead, POST a git bundle.

```bash
#!/bin/bash
# Discovery callback — executed on each peer announcement.
# Env: HOST_NAME, PEER_CERT_FILE, PEER_NETLOC, OUR_CERT, OUR_KEY
# Extra (operator-defined): REPOS_ROOT — directory of local git repositories.

mtls_curl() { ... }          # GET helper (feature 002)
mtls_curl_post() { ... }     # POST helper (this feature)

: "${REPOS_ROOT:?REPOS_ROOT must point at the local repositories}"

synced=0
skipped=0

for repo in "$REPOS_ROOT"/*/; do
  [ -d "$repo" ] || continue
  name="$(basename "$repo")"

  local_head="$(git -C "$repo" rev-parse HEAD 2>/dev/null)"
  peer_head="$(mtls_curl "/head?repo=$name" 2>/dev/null)" || {
    echo "[$name] head lookup failed; skipping"
    skipped=$((skipped + 1))
    continue
  }

  if [ "$local_head" = "$peer_head" ]; then
    echo "[$name] in sync"
    skipped=$((skipped + 1))
    continue
  fi

  if git -C "$repo" merge-base --is-ancestor "$peer_head" "$local_head" 2>/dev/null; then
    bundle="$(mktemp)"
    git -C "$repo" bundle create "$bundle" HEAD >/dev/null
    echo "[$name] pushing bundle $local_head"
    if mtls_curl_post "/bundle?repo=$name" "$bundle" 2>/dev/null; then
      synced=$((synced + 1))
      echo "[$name] pushed"
    else
      echo "[$name] push failed; skipping"
      skipped=$((skipped + 1))
    fi
    rm -f "$bundle"
  else
    echo "[$name] diverged or behind peer; skipping"
    skipped=$((skipped + 1))
  fi
done

echo "synced=$synced skipped=$skipped"
```

## Demo Test Topology

The BATS demo (`tests/smoke.bats`) exercises this contract with exactly one live server (playing the peer side) and a simulated local side:

```
/tmp/<test>/local/{alpha,beta,gamma,delta}    # simulated local side; callback acts here
/tmp/<test>/peer/{alpha,beta,gamma,delta}     # served by the one live instance
```

The test invokes the callback script directly with the peer's context (env vars per the 002 contract), which is exactly what the server would spawn after a discovery event. Assertions:

- `alpha` and `beta` peer repos reach local HEADs (bundle pushed).
- `gamma` receives no bundle (already in sync).
- `delta` receives no bundle (histories diverged).

## Error Handling (unchanged, plus:)

| Scenario | Behavior |
|---|---|
| Bundle POST rejected (e.g., diverged history, 500) | `mtls_curl_post` non-zero; the callback logs and continues with the next repo |
| HEAD lookup fails (peer unreachable / 500) | `mtls_curl` non-zero; repo skipped |
