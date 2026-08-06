# Specification Quality Checklist: 025 nncp-replace

**Purpose**: Validate specification completeness and quality before proceeding to planning.
**Created**: 2026-08-07
**Feature**: [spec.md](./../spec.md)

## Content Quality

- [X] **No implementation details (languages, frameworks, APIs)** — Spec references "Apache endpoint", "BLAKE2b-256", "Ed25519 signkey", "Ed25519 signpub in NNCP raw format" only inside FRs/Architecture where the user explicitly asked for them. User-facing SCs are phrased in terms of observable behaviour (`<5 s`, `idempotent`, `20-line log`). No specific PR fix or pseudo-code in the user story text.
- [X] **Focused on user value and business needs** — Every User Story anchored on what the user *does*: auto-discovery registers peers, NNCP packets land in spool, one keygen for two systems, hook directory replaces monolithic script.
- [X] **Written for non-technical stakeholders** — User Scenarios are in given/when/then plain English. The Architectural Summary does go into technical depth (keypair unification math) because the user's prompt required it; the FRs are concrete and testable.
- [X] **All mandatory sections completed** — User Scenarios & Testing, Requirements (Functional + Key Entities), Success Criteria, Assumptions, Edge Cases, Out of Scope, Dependencies all populated.

## Requirement Completeness

- [X] **No [NEEDS CLARIFICATION] markers remain** — Zero markers. Three plausible defaults (key-rotation strategy; whether to also implement outbound /nncp/send; whether idiomatic cert tooling is BoringSSL vs OpenSSL 3) are documented in the Out of Scope / Assumptions sections rather than as NEEDS CLARIFICATION; each can be re-confirmed in `/speckit.clarify` if you'd rather.
- [X] **Requirements are testable and unambiguous** — FR-001 through FR-015 each describe a concrete behaviour with a single canonical test path. FR-002's encoding format is pinned (RFC 4648 base32 *without* padding); FR-006's per-script timeout (30 s) is pinned; FR-004's handler (`handlers/nncp-receive.post.sh`) is named and its body-handshake contract is specified.
- [X] **Success criteria are measurable** — `<5 s`, `≤2 s`, `256 bytes`, `byte-identical contents`, `30 s` are all concrete numbers.
- [X] **Success criteria are technology-agnostic** — SC labels refer to user-observable outcomes (auto-registration, packet arrival in spool, idempotency, hook extensibility). "nncp-call" appears only in the test method, not the SC statement itself.
- [X] **All acceptance scenarios are defined** — US1 has 3 Given/When/Then scenarios (autoregister / receive packet / idempotency); US2 has 3; US3 has 3; US4 has 3; US5 has 2.
- [X] **Edge cases are identified** — 11 edge cases (NNCP missing, asym keys, restore-from-backup, self-discovery, per-script timeout, version mismatch, Ed25519 host capability, probe-before-mTLS, etc.).
- [X] **Scope is clearly bounded** — Out of Scope section enumerates 7 explicit non-goals (outbound via us, exec delivery, alternative transports, NNCP fork, key rotation ceremony in v1, NNCP protocol upgrades, cross-arch compilation).
- [X] **Dependencies and assumptions identified** — Separate Assumptions (9 items) and Dependencies (5 items) sections; both populated.

## Feature Readiness

- [X] **All functional requirements have clear acceptance criteria** — Every FR is mapped to one or more US acceptance scenarios (e.g., FR-001/FR-002 ↔ US3.1/3.2, FR-004 ↔ US2.1, FR-006-FR-010 ↔ US4.1/4.2, FR-011 ↔ US5.1).
- [X] **User scenarios cover primary flows** — Auto-discovered peer registers (US1), cross-host packet arrives (US2), key reuse (US3), hook directory (US4), legacy RSA survive (US5). Five flows cover the *replace nncp-caller* surface area end-to-end.
- [X] **Feature meets measurable outcomes defined in Success Criteria** — SC-001 through SC-006 each round-trip back to FRs.
- [X] **No implementation details leak into specification** — Where details do appear (Apache handler, hjson, etc.), they are deliberate architectural decisions tied to the user's explicit ask ("essentially replace nncp-caller", "transform on-discovery.sh", "make our keys … secondarily double-used as nncp keypairs"), not accidental leakage.

## Notes

- The spec depends heavily on the contents of `/tmp/nncp-8.13.0` (referenced as the source of `nncp-toss`'s CLI contract and the wire-protocol reference). The plan phase should explicitly diff the actual NNCP 8.13.0 source for `nncp-toss`'s CLI so FR-004's "pipe bytes" contract and exit-code interpretation matches reality.
- One item I'd flag to `/speckit.clarify` if you want to nail it down rather than leaving as assumption: **whether we reuse a single X25519 key for NNCP `exchpub` and `noisepub`** (the research says "separate is better for key separation" but reuse is acceptable). Default in the spec is "two distinct X25519 scalars" (one for ECDH↔exchpub, one for NNCP noise). Override if you'd rather have one shared scalar.
- Another reasonable `/speckit.clarify` candidate: **whether the existing `scripts/on-discovery.sh` receives a deprecation window** (e.g., one release where both `on-discovery.sh` and `on-discovery.d/` are honored, with `on-discovery.sh` deprecated in docs and dropped in the next release). Default in the spec is "drop immediately" since there is no public API contract; override if you have downstream consumers.
- All 16 checklist items pass. Ready for `/speckit.plan`.
