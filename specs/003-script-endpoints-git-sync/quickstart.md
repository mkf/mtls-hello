# Quickstart: Script-Executing Endpoints and Multi-Repo Git Sync Demo

**Branch**: `003-script-endpoints-git-sync` | **Date**: 2026-03-19 | **Feature**: [spec.md](./spec.md)

## Prerequisites

- Features 001 and 002 built and working (this feature extends both).
- GNU Guix with the daemon running.
- Git checkout of this branch.

## 1. Build

```sh
just build
```

(`guix.scm` now also provides `git`, used by the demo test.)

## 2. Write a handler script

Handler scripts live in the handlers directory (default `handlers/`), named `<name>.<method>.<ext>` — lowercase method infix, any extension. GET and POST are separate files.

```sh
# handlers/head.get.sh  (chmod +x)
#!/bin/bash
git -C "$REPOS_ROOT/$QUERY_REPO" rev-parse HEAD
```

```sh
# handlers/bundle.post.sh  (chmod +x)
#!/bin/bash
set -euo pipefail
tmp="$(mktemp)"; trap 'rm -f "$tmp"' EXIT
cat > "$tmp"
git -C "$REPOS_ROOT/$QUERY_REPO" fetch "$tmp" HEAD
git -C "$REPOS_ROOT/$QUERY_REPO" merge --ff-only FETCH_HEAD
echo "ok"
```

## 3. Run

The handlers need `REPOS_ROOT` to locate the git repositories:

```sh
REPOS_ROOT=/path/to/repos just run -- 8443 --handlers-dir handlers
```

Without `REPOS_ROOT`, the example git handlers will fail at runtime.

## 4. Call the endpoints

```sh
# GET with a query parameter → script env: QUERY_STRING=repo=alpha, QUERY_REPO=alpha
curl -sS --cacert certs/certs/ca.crt \
     --cert certs/certs/client.crt --key certs/private/client.key \
     "https://localhost:8443/head?repo=alpha"

# POST with a body → body on script stdin
git bundle create /tmp/alpha.bundle HEAD
curl -sS --cacert certs/certs/ca.crt \
     --cert certs/certs/client.crt --key certs/private/client.key \
     --data-binary @/tmp/alpha.bundle \
     "https://localhost:8443/bundle?repo=alpha"
```

Backward compatibility: `GET /hello` with no `hello.get.*` script still echoes `hello`; `POST /hello` returns 404.

## 5. Multi-repo git sync demo (automated)

The BATS demo (`tests/smoke.bats`) exercises the whole picture with one live server:

```text
/tmp/<test>/local/{alpha,beta,gamma,delta}    # simulated local side (callback acts here)
/tmp/<test>/peer/{alpha,beta,gamma,delta}     # served by the one live instance
```

- `alpha` and `beta` get extra local commits (local ahead); `gamma` stays in sync; `delta` is deliberately diverged.
- The callback (feature 002 contract) is invoked directly with the peer's env context.
- For each repo it GETs `/head?repo=<name>` via `mtls_curl`, and if the local HEAD strictly advances the peer HEAD, it bundles and POSTs via `mtls_curl_post`.
- Assertions: peer `alpha`/`beta` reach local HEADs; `gamma` receives no bundle; `delta` is left unchanged.

## 6. Automated tests

```sh
just test
```

## Troubleshooting

- **400 on a request**: the handler name contains `/`, `\`, or `.` — names must be plain slugs (dots are structural in file names).
- **Script "not found"**: file must be `handlers/<name>.get.*` or `handlers/<name>.post.*` and executable (`chmod +x`).
- **500 from a script**: script exited non-zero or hit `--script-timeout` (default 10 s); check server logs for the captured stderr.
- **Demo sync fails on merge**: histories must be linear for fast-forward; diverged repos are logged, not merged (out of scope).
- **Scripts fail with glibc version errors inside the Guix shell**: the server automatically clears `LD_LIBRARY_PATH` for child scripts so that host binaries (e.g. `/bin/bash`) load the host libc rather than the Guix profile's libc. This is a Guix-specific runtime fix and does not affect deployments that run the binary directly on the host.
