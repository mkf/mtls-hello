# Implementation Plan: Hostname-Matched Certificate Trust

**Branch**: `004-hostname-cert-trust` | **Date**: 2026-08-05 | **Spec**: [spec.md](./spec.md)

**Input**: Feature specification from `/specs/004-hostname-cert-trust/spec.md`

## Summary

Replace the blanket CA-based client-certificate trust with explicit per-hostname pinning. A peer is trusted only when a certificate file is present in a local trust store under the peer's hostname (derived from the client certificate's name) AND the presented certificate matches that file (SHA-256 fingerprint). There is no trust-on-first-use. Peers whose certificates are not (yet) trusted have their certificates captured into a "purgatory" directory for operator review — capture confers no trust. The operator promotes a purgatory certificate to trusted status by installing it in the trust store under the matching hostname (helper script `scripts/trust-host.sh` + onboarding documentation in `quickstart.md`).

## Technical Context

**Language/Version**: D — LDC 1.27.1 (frontend 2.097) via Guix; host has LibreSSL which breaks deimos OpenSSL bindings, so Guix remains the build target (same constraint as features 001–003).

**Primary Dependencies**: vibe-d 0.10.3 (vibe-http 1.5.1, vibe-core 2.14.0), deimos `openssl` bindings 3.4.0 (`TLSPeerValidationMode`), std.digest (SHA-256 fingerprint comparison), std.process / std.stdio (existing), openssl CLI (test PKI only), git (test-only, existing).

**Storage**: Filesystem — trust store directory (`certs/hosts/` by default, per feature 002's `certs/hosts/<hostname>.crt` convention) and purgatory directory (`certs/purgatory/` by default). No database.

**Testing**: BATS (`tests/smoke.bats`) for end-to-end HTTPS/mTLS trust behavior: accepted trusted peer, rejected unknown peer, purgatory capture + idempotency, promotion flow, and updated legacy trust tests. No multicast involvement (this feature is about inbound trust, not discovery).

**Target Platform**: Linux (x86_64), LAN-connected hosts. Deployed via `guix shell -f guix.scm`.

**Project Type**: web-service (HTTPS server, single binary) with a per-hostname certificate trust store.

**Performance Goals**: LAN-scale — a handful of instances, low request rate. Trust evaluation is a local file lookup + SHA-256 comparison; must not block the event loop beyond the existing handshake cost.

**Constraints**: Same Guix/LDC/OpenSSL build constraints as features 001/002. TLS client-cert verification mode changes from `requireCert|checkCert|checkTrust` (CA) to `requireCert|checkCert` (permissive) with trust decided at the application layer — this is required to observe unknown certificates for purgatory. Hostname is derived from the client certificate's name (CN, fallback first DNS SAN); certs without a usable name are rejected. Fingerprint comparison uses SHA-256 of the DER-encoded certificate. Stored certificate validity (expiry) is checked at trust time. The existing 4th positional CLI argument (client CA) remains accepted for CLI-contract stability but no longer governs inbound client trust.

**Scale/Scope**: New `source/trust.d` module (trust store lookup, purgatory capture, fingerprinting, hostname derivation); CLI options `--trust-dir` / `--purgatory-dir`; changed `peerValidationMode` in `source/app.d`; new `scripts/trust-host.sh`; updated `tests/smoke.bats` (trust fixture helpers + new trust tests, existing tests adapted to the trust store); onboarding doc (`quickstart.md`). ~150–200 additional lines of D, ~60 lines of bash.

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

- `.specify/memory/constitution.md` is an unfilled template — no named principles or binding gates exist.
- **Result: PASS** (no gate violations possible). Re-checked after Phase 1: no new gates introduced; still PASS.

## Project Structure

### Documentation (this feature)

```text
specs/004-hostname-cert-trust/
├── plan.md              # This file
├── research.md          # Phase 0 output
├── data-model.md        # Phase 1 output
├── quickstart.md        # Phase 1 output — THE onboarding doc (trust a peer's self-signed cert)
├── contracts/           # Phase 1 output
│   ├── cli.md           # New CLI options (--trust-dir, --purgatory-dir) + repositioned client CA arg
│   └── trust.md         # Trust decision procedure, store/purgatory layout, promotion
└── tasks.md             # Phase 2 output (/speckit.tasks — NOT created by /speckit.plan)
```

### Source Code (repository root)

```text
source/
├── app.d               # wiring; TLS context: peerValidationMode → requireCert|checkCert (app-layer trust)
├── trust.d             # NEW: hostname derivation, trust store lookup, fingerprint, purgatory capture
├── handlers.d          # script endpoints (feature 003) — unchanged
└── multicast.d         # discovery (feature 001) — unchanged

scripts/
├── gen_certs.sh        # PKI generation (existing)
├── on-discover.sh      # discovery callback (features 002/003) — unchanged
└── trust-host.sh       # NEW: promote a purgatory/obtained cert to the trust store under a hostname

certs/
├── hosts/              # trust store (per-host certs, `<hostname>.crt`) — created at runtime
└── purgatory/          # quarantine for untrusted peers' certs — created at runtime

tests/
└── smoke.bats          # extended: trust store helpers + new trust/purgatory/promotion tests; adapted legacy tests
```

**Structure Decision**: Same single-binary layout as features 001–003. New `source/trust.d` module keeps the trust logic out of `app.d`. The trust store and purgatory are plain directories under `certs/`, consistent with feature 002's `certs/hosts/<hostname>.crt` convention. `scripts/trust-host.sh` is the operator-facing promotion tool; `quickstart.md` is the onboarding doc the user asked for.

## Complexity Tracking

> No constitution violations. No complexity justifications required.
