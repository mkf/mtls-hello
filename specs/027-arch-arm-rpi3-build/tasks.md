# Tasks: Arch Linux ARM (RPi 3 Model B v1.2) Cross-Compilation Build Flow

**Input**: Design documents from `/specs/027-arch-arm-rpi3-build/`

**Prerequisites**: plan.md (required), spec.md (required), research.md, data-model.md, contracts/, quickstart.md

**Organization**: Tasks grouped by user story. US1 is the primary deliverable — the package assembling and validating pipeline. US2 wires CI integration on top. US3 is reproducibility, easier to retrofit. Each foundational task blocks all three user stories; the user-story phases run in priority order but can be tackled in parallel once foundation is done.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no dependencies)
- **[Story]**: Which user story this task belongs to (`[US1]`, `[US2]`, `[US3]`)
- Include exact file paths in descriptions

## Phase 1: Setup (Project Initialization)

**Purpose**: Make sure the new directories exist before tasks start writing files into them.

- [X] T001 [P] Create the PKGBUILD staging directory `docker/pkgbuilds/` (parent `docker/` already exists)
- [X] T002 [P] Create the cross-arm cross-build script's place at `scripts/package-arch-rpi3.sh` by writing a 1-line stub (just a `#!/usr/bin/env bash` shebang — full content lands in T004); this guarantees the file exists so subsequent chmod+edit doesn't have a race

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: All four cross-build foundational files written. Without these, every user story is blocked.

**⚠️ CRITICAL**: No user story work can begin until this phase is complete.

- [X] T003 [P] Create `docker/Dockerfile.arch-rpi3` with `FROM archlinux:latest`, install `pacman` only, set `WORKDIR /build`, mount points `/src` (read-only) + `/out` (writable), and `CMD` running `bash scripts/package-arch-rpi3.sh`. Note: cross-toolchain arrives via `makedepends` resolved by `makepkg -s` inside the build, NOT pre-baked here.
- [X] T004 [P] Create `docker/pkgbuilds/mtls-hello.PKGBUILD` declaring `pkgname=mtls-hello`, `arch=('armv7h')`, `pkgver`+`pkgrel=1`, `pkgdesc`, `url`, `license=('MIT')`, `depends=('apache' 'bash' 'openssl' 'git' 'coreutils' 'grep' 'findutils' 'sed' 'awk' 'glibc' 'zstd')`, `makedepends=('arm-linux-gnueabihf-gcc' 'arm-linux-gnueabihf-binutils' 'arm-linux-gnueabihf-glibc' 'arm-linux-gnueabihf-linux-api-headers' 'ldc' 'dub' 'pkgconf' 'make' 'git' 'openssl' 'zstd' 'go' 'pacman')`, and `build()`/`package()` shells that set `LD_FLAGS=--target=armv7-unknown-linux-gnueabihf` for dub and `GOARCH=arm GOARM=7 CGO_ENABLED=0` for go, then call `scripts/package-common.sh:build_binary` and `stage_install_tree`.
- [X] T005 [P] Fill in `scripts/package-arch-rpi3.sh` (created as stub in T002) — body runs `set -euo pipefail`, `unset LD_LIBRARY_PATH`, `cd $(dirname ...)/..`, sources `scripts/package-common.sh` and `scripts/cleanup-common.sh`, sets `PKGEXT=.pkg.tar.zst`, `SRCPKGDEST=/out`, `BUILD_DIR=/build/pkg`, and ends by `exec makepkg -s` from `docker/pkgbuilds/`. No new `rm -rf` may be introduced; reuse `remove_file_safe` and `rmdir` from the existing helper scripts (G1).
- [X] T006 Add a new `package-arch-arm-rpi3` recipe to the project root `justfile` that runs `docker build -f docker/Dockerfile.arch-rpi3 -t mtls-hello-arm-rpi3-build .` then `docker run --rm -v $REPO:/src:ro -v $REPO/dist:/out mtls-hello-arm-rpi3-build`, finally targets the emitted package file in `dist/` for the in-container smoke test.
- [X] T007 Add a new CI job `package-arch-arm-rpi3` to `.github/workflows/ci.yml` (runs on `ubuntu-latest`) that runs `just package-arch-arm-rpi3` and uploads `dist/mtls-hello-*-armv7h.pkg.tar.zst` via `actions/upload-artifact@v4` named `mtls-hello-armv7h`. The job runs in parallel with the existing native arch + deb jobs.

**Checkpoint**: at the end of this phase, `./just package-arch-arm-rpi3` will (theoretically) produce a `.pkg.tar.zst` in `dist/` — US1 verification establishes whether it actually does.

---

## Phase 3: User Story 1 — Operator deploys on Raspberry Pi 3 Model B v1.2 (P1) 🎯 MVP

**Goal**: A clean `just package-arch-arm-rpi3` produces a `.pkg.tar.zst` that `pacman -U` accepts on Arch Linux ARM RPi 3 (or via qemu) and whose `mtls-hello --version` exits 0 within 10 seconds.

**Independent Test**: Try running `just package-arch-arm-rpi3` from a clean clone on a host with Docker; `ls dist/mtls-hello-*-armv7h.pkg.tar.zst` shows the file. Then `tar -xOf <pkg> .PKGINFO | grep '^arch ='` returns `arch = armv7h`.

### Implementation for User Story 1

- [.] T008 [US1] Run `just package-arch-arm-rpi3` end-to-end from a clean working tree; assert that `dist/mtls-hello-*-armv7h.pkg.tar.zst` exists after the recipe exits 0. On failure, attach the container's stderr to the failure ticket and proceed with the next dependent tasks.
- [.] T009 [P] [US1] Verify that the produced package's `.PKGINFO` declares `arch = armv7h`: `tar -xOf dist/mtls-hello-*-armv7h.pkg.tar.zst .PKGINFO | grep '^arch ='`. This is one of the eight Success Criteria (SC-001).
- [.] T010 [P] [US1] Verify that the cross-compiled binary is actually ARMv7 + Linux EABI5: extract `usr/bin/mtls-hello` from the package and run `file` against it (SC-004). Repeat for `var/lib/mtls-hello/bin/nncp-toss` (FR-007 mandates that no x86 artifacts leak into the package).
- [.] T011 [P] [US1] Verify the package's payload contains all expected paths: `tar -tf dist/mtls-hello-*-armv7h.pkg.tar.zst | sort | uniq` matches the canonical layout in `specs/027-arch-arm-rpi3-build/contracts/pkg-format.md` (FR-004, FR-005).
- [.] T012 [US1] In `.specify/scripts/bash/test-arm-rpi3-chroot.sh` (new file under `.specify/scripts/bash/` — easier than ad-hoc), write the qemu-arm-static chroot install test: extract the package into a docker-mounted `archlinuxarm/armv7h/base` chroot, run `pacman -U` from inside it, then `/usr/bin/mtls-hello --version`; assert exit code 0 + non-empty stdout within 10 s (SC-002, SC-003). Wire this into the justfile recipe as `_test-arm-rpi3-package` so `just package-arch-arm-rpi3` runs it automatically on the host that has `qemu-arm-static` + binfmt_misc registered.

**Checkpoint**: At the end of US1, the build produces a verifiable, executable ARMv7 package. This is the MVP.

---

## Phase 4: User Story 2 — CI builds armv7h alongside other archs (P2)

**Goal**: The cross-build runs inside the GitHub Actions matrix on every push and on every release tag, producing an artifact named `mtls-hello-armv7h` alongside the existing `.deb` and native-arch artifacts.

**Independent Test**: Push or PR a commit; `gh run watch` until `package-arch-arm-rpi3` completes. The run's artifacts list contains `mtls-hello-armv7h` (the `.pkg.tar.zst`).

### Implementation for User Story 2

- [ ] T013 [US2] Trigger the existing `.github/workflows/ci.yml` on a draft PR confirming the new `package-arch-arm-rpi3` job passes (SC-007). Record the job URL.
- [ ] T014 [P] [US2] Extend the existing release-attach step in `.github/workflows/ci.yml` to upload `dist/mtls-hello-*-armv7h.pkg.tar.zst` alongside the existing `.deb` and native `.pkg.tar.zst` artifacts on tagged commits.
- [ ] T015 [P] [US2] Add a one-line note in `README.md` (or maintain release-process doc) that an armv7h artifact is available starting from the next release, with a wget URL template per the existing release-attach pattern.

**Checkpoint**: US1 + US2 working = armv7h builds ship through CI/release.

---

## Phase 5: User Story 3 — Reproducible build across machines (P3)

**Goal**: Two containers building the same source SHA produce a `.pkg.tar.zst` whose payload files are byte-identical (timestamps free).

**Independent Test**: Build twice from the same source commit; `tar -xf <pkg-1> -C /tmp/v1 && tar -xf <pkg-2> -C /tmp/v2 && diff -r --brief --exclude=.PKGINFO /tmp/v1 /tmp/v2` returns no differences.

### Implementation for User Story 3

- [ ] T016 [US3] Verify that `scripts/package-arch-rpi3.sh` derives `SOURCE_DATE_EPOCH` from the latest git commit's author date (`git log -1 --format=%ct`), not the wall clock. If it isn't already, add a one-liner that does so and pass the value through to makepkg's `PKGBUILD`'s `build()` so `builddate =` is deterministic.
- [ ] T017 [P] [US3] Add a BATS reproducer test at `tests/arch-arm-rpi3-bats` (file `tests/arch-arm-rpi3.bats`) that builds twice from the same fixture and `diff`s the two payloads (excluding `.PKGINFO`/`./.MTREE`). Green = byte-identical payload. Skip cleanly (no fail) if `docker` isn't on PATH — same convention as the existing `tests/apache.bats` us.
- [ ] T018 [P] [US3] Update `specs/027-arch-arm-rpi3-build/quickstart.md` reproducibility section with the verification commands (build twice → diff), per the existing convention of `data-model.md` listing reproducibility invariants explicitly.

**Checkpoint**: US1 + US2 + US3 working.

---

## Phase 6: Polish & Cross-Cutting Concerns

**Purpose**: Validate, document, and protect against regressions.

- [ ] T019 [P] Run `shellcheck --severity=warning docker/Dockerfile.arch-rpi3 docker/pkgbuilds/mtls-hello.PKGBUILD scripts/package-arch-rpi3.sh justfile` — note: Dockerfile is exempt, but anything else with shellcheck findings must be fixed (G5).
- [ ] T020 [P] Run `bash -n scripts/package-arch-rpi3.sh` to confirm syntax (apparent in any shell, but cheap insurance).
- [ ] T021 Verify that the existing native `just install` (or whatever the x86_64 path is) still works after the cross-arm additions. This is a regression guard, not a new feature — if it fails, the cross-arm work introduced an unintended dep on something not in scope.
- [ ] T022 Update `README.md` so its top-level "Building" section links to `specs/027-arch-arm-rpi3-build/quickstart.md` (one anchor link, no duplicated prose).

---

## Dependencies & Execution Order

### Phase Dependencies

- **Setup (Phase 1)**: No dependencies — runs immediately.
- **Foundational (Phase 2)**: Depends on Setup completion; BLOCKS all user stories.
- **User Stories (Phases 3+)**: All depend on Foundational completion.
  - Internal ordering: US1 (P1) runs first, then US2 (P2) refines CI, then US3 (P3) refines reproducibility. Each story gates the next.
- **Polish (Phase 6)**: Depends on all desired user stories being complete.

### User Story Dependencies

- **US1 (P1)**: Independent — can start after Foundational completes.
- **US2 (P2)**: Depends on US1 (CI job depends on the build command existing and working). Independently testable by checking artifact upload via `gh run watch`.
- **US3 (P3)**: Independently testable by running the reproducer test in isolation. Implementation-wise, can be developed in parallel with US2 if the SOURCE_DATE_EPOCH line is added upfront.

### Within Each User Story

- T008 blocks T009/T010/T011 (need a real package first).
- T012 is independent of T009/T010/T011 — qemu test is a separate execution.
- T015 depends on T013 being able to run successfully.

### Parallel Opportunities

- All of T003, T004, T005, T006, T007 are parallelizable — all write different files (Foundational).
- All of T009, T010, T011 are parallelizable — they verify the same package read from disk (read-only checks).
- T015 and T018 are parallelizable — one is a workflow change, one is doc.

---

## Parallel Examples

### Foundational phase (5 files in parallel)

```bash
# Five LLM agents work in parallel on these files:
T003: docker/Dockerfile.arch-rpi3       (Dockerfile)
T004: docker/pkgbuilds/mtls-hello.PKGBUILD  (PKGBUILD)
T005: scripts/package-arch-rpi3.sh       (driver script)
T006: justfile                          (justfile recipe)
T007: .github/workflows/ci.yml           (CI job)
```

### US1 verification (3 read-only checks in parallel)

```bash
# Once T008 produced dist/...pkg.tar.zst, run these in parallel:
T009: tar -xOf <pkg> .PKGINFO | grep '^arch ='
T010: tar -xOf <pkg> usr/bin/mtls-hello | file -
T011: tar -tf <pkg> | diff -u <(tar -tf <pkg> | sort) <(printf '.PKGINFO\n.INSTALL\n.MTREE\n...')
```

---

## Implementation Strategy

### MVP first (US1 only)

1. Phase 1 (T001, T002) — directories/locks in place.
2. Phase 2 (T003, T004, T005, T006, T007) — all cross-arm plumbing.
3. Phase 3 (T008, T009, T010, T011, T012) — the package builds + verifies.
4. **STOP & DEMO**: that single artifact, opened in a chroot, runs `mtls-hello --version`.

### Incremental delivery

1. Phase 1 + Phase 2 → build infrastructure ready (no defensive output yet).
2. + US1 → MVP: armv7h package installable and executable.
3. + US2 → CI shipping the package on every build.
4. + US3 → byte-deterministic builds, security audit-ready.

---

## Notes

- **No new runtime dependencies** (G8): the cross-build only adds **build** dependencies (makedepends). Runtime dependencies are added via the package's PKGINFO `depend =` lines, in line with the user's 2026-08-07 correction.
- **No host toolchain required** (FR-008): every task in Foundational, US1, US2, US3 runs in or against a container. The host only needs Docker.
- **Safety rule G1**: no `rm -rf`, no `find -delete`. All cleanup uses `remove_file_safe`, `rm`, or `rmdir` on anchored paths. The cross-arm workflow reuses `scripts/package-common.sh:cleanup_pkgroot` as-is.
- **Reproducibility (US3)**: `SOURCE_DATE_EPOCH` derivation + `makepkg` determinism is sufficient for payload-byte equality. The `.PKGINFO` and `.MTREE` files will still differ in timestamps; that's acceptable per FR-009.
- **Reuse over duplication**: `scripts/package-arch-rpi3.sh` does NOT reimplement package building — it delegates to `scripts/package-common.sh:build_binary()` and `stage_install_tree()`. Single source of truth (G9).
- **Tests are optional per the project convention** (see `specs/014-cert-discovery-tests` history) — we include only what validates behavior that's hard to inspect post-hoc (artifact contents + reproducer). Functional smoke tests stay with the artifact itself.

Total task count: **22** (2 setup + 5 foundational + 5 US1 + 3 US2 + 3 US3 + 4 polish).


## Implementation status (this branch)

T008–T012 are marked `[.]` (blocked) — see `git log` for the five
tried strategies and their actual failure modes. The artefacts
labelled in spec 027 (PKGINFO `arch = armv7h`, ARMv7 ELF binary,
chroot install via `pacman -U`) are not generated in this dev
container. They will be produced when the Dockerfile is run on a
canonical CI runner with the file paths shown by the latest verbatim
build in this branch.
