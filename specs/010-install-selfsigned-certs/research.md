# Research: Install-Time Self-Signed Certificates

## Decision: Generate certs in install.sh with `openssl req -x509`

**Decision**: Use `openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -keyout ... -out ... -subj "/CN=$(hostname)"` to generate self-signed certificates during install.

**Rationale**:
- One-liner, no CA, no CSR, no config files
- `-x509` produces a self-signed certificate directly
- `-nodes` skips passphrase (server needs unattended startup)
- 10-year validity avoids expiration churn
- CN=hostname provides meaningful identity for the trust onboarding flow

**Alternatives considered**:
- `openssl genrsa` + `openssl req` (two steps) — more verbose, no benefit
- `openssl ecparam` (ECDSA) — faster, smaller keys, but less universally supported by older clients

## Decision: Per-test certificate generation in BATS

**Decision**: Each BATS test generates fresh self-signed certs via a `mkfixture_certs` helper. No committed cert fixtures.

**Rationale**:
- Committed certs expire (they have a 1-day validity period in tests) — per-test generation avoids expiration failures
- `openssl req -x509` takes ~50ms — negligible per-test overhead
- No CA means no chain verification — `--cacert` points directly to the server's self-signed cert
- Each test gets isolated certs, preventing cross-test contamination

**Alternatives considered**:
- Commit long-lived self-signed certs — simpler but creates maintenance burden when they eventually expire
- Reuse a single set of certs across all tests — risks test interdependency if one test modifies certs

## Decision: Curl `--cacert SERVER_CERT` for self-signed servers

**Decision**: In BATS tests, use `curl --cacert "$SERVER_CERT"` to trust the server's self-signed certificate. Replace `--cacert certs/certs/ca.crt`.

**Rationale**:
- With self-signed certs, the server's certificate IS the trust anchor
- `--cacert` pointing to the server cert makes curl accept it
- Same flag, different argument — minimal diff

**Alternatives considered**:
- `curl -k` (insecure) — suppresses all verification, masks real TLS issues
- `curl --cacert` pointing to a generated-on-the-fly CA — adds complexity with no benefit

## Decision: Remove gen_certs.sh and committed certs/

**Decision**: Delete `scripts/gen_certs.sh` and all committed files under `certs/`. The `just gen-certs` recipe is removed.

**Rationale**:
- No CA means gen_certs.sh has no purpose — it generated a CA-based PKI
- Committed certs would expire — better to generate on demand
- The `mkfixture_certs` BATS helper and the install.sh generation cover all use cases
