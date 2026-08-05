# Specification Quality Checklist: Wire Discovery Callback

**Purpose**: Validate specification completeness and quality before proceeding to planning
**Created**: 2026-08-05
**Feature**: [spec.md](../spec.md)

## Content Quality

- [x] No implementation details (languages, frameworks, APIs)
- [x] Focused on user value and business needs
- [x] Written for non-technical stakeholders
- [x] All mandatory sections completed

## Requirement Completeness

- [x] No [NEEDS CLARIFICATION] markers remain
- [x] Requirements are testable and unambiguous
- [x] Success criteria are measurable
- [x] Success criteria are technology-agnostic (no implementation details)
- [x] All acceptance scenarios are defined
- [x] Edge cases are identified
- [x] Scope is clearly bounded
- [x] Dependencies and assumptions identified

## Feature Readiness

- [x] All functional requirements have clear acceptance criteria
- [x] User scenarios cover primary flows
- [x] Feature meets measurable outcomes defined in Success Criteria
- [x] No implementation details leak into specification

## Notes

- All items pass. Ready for `/speckit.plan`.
- Debouncing is explicitly deferred to a future optimization.
- HOST_NAME defaults to "localhost" if not set — sensible out-of-box behavior.

---

## Domain Requirements Quality Review

**Purpose**: Deep-dive into discovery protocol, process spawning, and production install requirements
**Created**: 2026-08-05
**Focus**: Protocol + Spawn + Install (balanced)

### Discovery Protocol Requirements

- [ ] CHK001 Is the full announcement JSON schema documented (all fields, their types, and which are required vs optional)? [Completeness, Spec §Key Entities]
- [ ] CHK002 Is the self-ignore criterion unambiguously defined — does it match on port alone, or host+port, or source address? [Clarity, Spec §FR-007]
- [ ] CHK003 Are requirements specified for backwards compatibility when a legacy peer sends an announcement without the `host` field? [Coverage, Spec §Edge Cases]
- [ ] CHK004 Is the default HOST_NAME value (`"localhost"`) appropriate for multi-machine LANs where multiple instances would collide? [Assumption, Spec §FR-001]
- [ ] CHK005 Are requirements defined for IPv6 addresses in the announcement and PEER_NETLOC construction? [Coverage, Gap]

### Process Spawning Requirements

- [ ] CHK006 Is the callback script execution contract fully specified — bash interpreter, working directory, inheriting parent stdout/stderr? [Completeness, Spec §FR-004]
- [ ] CHK007 Are the environment variable names and semantics defined for all six variables passed to the callback? [Completeness, Spec §Key Entities]
- [ ] CHK008 Is the failure-mode taxonomy complete: file-not-found, permission-denied, non-zero exit, timeout? [Coverage, Spec §FR-006]
- [ ] CHK009 Are requirements specified for what happens when the callback script exits with a non-zero code? [Coverage, Gap]
- [ ] CHK010 Is the non-blocking requirement quantified — does "must not wait" mean zero blocking calls on the spawn path, or is a bounded timeout acceptable? [Clarity, Spec §FR-005]
- [ ] CHK011 Are resource limits addressed — is there a maximum number of concurrent callback processes, or is unbounded concurrency acceptable? [Coverage, Gap]

### Production Install Requirements

- [ ] CHK012 Are the install paths for all three artifacts (binary, handlers, callback script) consistent and documented in one place? [Consistency, Spec §FR-009]
- [ ] CHK013 Is the operator guidance for setting CALLBACK_SCRIPT after `just install` clearly documented in the spec? [Completeness, Spec §FR-010]
- [ ] CHK014 Does the systemd unit template reference CALLBACK_SCRIPT, or is it assumed the operator adds it to the service environment? [Coverage, Gap]
- [ ] CHK015 Is the behavior defined when CALLBACK_SCRIPT points to a non-existent path after install? [Edge Case, Spec §FR-006]

### Cross-Cutting Quality

- [ ] CHK016 Are the trust assumptions for PEER_CERT_FILE documented — what happens if the cert file exists but contains an untrusted or expired certificate? [Assumption, Spec §Assumptions]
- [ ] CHK017 Can all success criteria (SC-001, SC-002, SC-003) be verified without manual packet capture or multi-machine setup? [Measurability, Spec §Success Criteria]
- [ ] CHK018 Are the requirements for OUR_CERT / OUR_KEY consistent with the existing on-discover.sh contract — is mTLS client auth optional or required for the sync callback? [Consistency]
- [ ] CHK019 Is the debouncing deferral explicit — does the spec state that duplicate callbacks within a window are acceptable? [Completeness, Spec §Assumptions]
- [ ] CHK020 Are there requirements for observability — what log level, format, and content are expected for discovery events, spawn successes, and spawn failures? [Coverage, Gap]
