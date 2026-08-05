# Tasks: Native Distribution Packages

**Input**: Design documents from `/specs/012-native-dist-packages/`

**Prerequisites**: plan.md, spec.md, research.md, data-model.md, contracts/cli.md, quickstart.md

**Tests**: BATS — distro detection + package tree structure validation (Docker tests manual)

**Organization**: US4 (Docker build) is the MVP — it's the dev's primary path on openSUSE Slowroll. US1/US2 (native scripts) share the same `package-common.sh` core. US3 (distro detect) is a thin dispatcher.

---

## Phase 1: Setup

- [X] T001 Verify baseline: run `just test` on branch `012-native-dist-packages` and confirm existing tests pass before starting
- [X] T002 Add `dist/` to `.gitignore` so produced packages are not committed

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: The shared staging core that every build path calls.

- [X] T003 Create `scripts/package-common.sh` — a sourced helper that: (a) verifies `ldc2`/`dub` are on PATH (error if not, naming the `ldc` package); (b) runs `bash scripts/version.sh && dub build --compiler=ldc2`; (c) stages the install tree into a caller-provided root dir: `usr/bin/mtls-hello`, `usr/lib/mtls-hello/handlers/bundle.post.sh`, `usr/lib/mtls-hello/scripts/on-discover.sh`, `usr/lib/mtls-hello/scripts/pre-push.sh.new`, `usr/lib/systemd/user/mtls-hello.service` (with the absolute-path unit from data-model.md). Exposes a `stage_install_tree <rootdir>` function.
- [X] T004 [P] Write the shared systemd user unit content into `scripts/package-common.sh` as a heredoc — `/usr/bin/mtls-hello`, `/var/lib/mtls-hello/certs/...`, `--port=0 --port-file=%t/mtls-hello.port --data-dir=/var/lib/mtls-hello --no-multicast`, `Restart=on-failure`. (Part of T003 but called out for clarity.)

**Checkpoint**: `package-common.sh` can build the binary and stage a correct tree when sourced by a stub.

---

## Phase 3: User Story 4 - Docker Build (Priority: P1) 🎯 MVP

**Goal**: `just package-docker` on any host with Docker produces both a `.deb` and a `.pkg.tar.zst` in `dist/`.

**Independent Test**: On the openSUSE Slowroll dev host with Docker, run `just package-docker`, verify `dist/mtls-hello_*.deb` and `dist/mtls-hello-*.pkg.tar.zst` both exist.

### Implementation for User Story 4

- [X] T005 [US4] Create `docker/Dockerfile.debian` — `FROM debian:bookworm`; `apt-get update && apt-get install -y ldc dub libssl-dev pkg-config`; copy `scripts/package-debian.sh` and `scripts/package-common.sh` in; entrypoint runs the debian packaging against `/src` and copies the `.deb` to `/out/`.
- [X] T006 [US4] Create `docker/Dockerfile.arch` — `FROM archlinux:latest`; `pacman -Syu --noconfirm ldc dub openssl pkgconf`; copy `scripts/package-arch.sh` and `scripts/package-common.sh` in; entrypoint runs the arch packaging against `/src` and copies the `.pkg.tar.zst` to `/out/`.
- [X] T007 [US4] Create `docker/docker-build.sh` — check `docker` is on PATH and daemon is reachable (error clearly if not); `docker build -t mtls-hello-build-debian -f docker/Dockerfile.debian .`; `docker run --rm -v "$PWD:/src:ro" -v "$PWD/dist:/out" mtls-hello-build-debian`; same for arch; print which packages were produced.
- [X] T008 [US4] Add `package-docker` recipe to `justfile` — runs `bash docker/docker-build.sh`.

**Checkpoint**: `just package-docker` produces both packages on the dev machine.

> **Note**: T005/T006 depend on the Debian/Arch packaging scripts (T009/T011 below). In practice, build the packaging scripts first (they're in the Dockerfiles' context), then wire the Dockerfiles. The MVP ordering below reflects this.

---

## Phase 4: User Story 1 - Debian Package (Priority: P1)

**Goal**: `just package-debian` on a Debian host produces `dist/mtls-hello_<version>_amd64.deb`.

**Independent Test**: On Debian, `just package-debian` then `dpkg-deb -I dist/*.deb` shows control with Depends; `dpkg-deb -c dist/*.deb` lists the install tree.

### Implementation for User Story 1

- [X] T009 [US1] Create `scripts/package-debian.sh` — source `package-common.sh`; `stage_install_tree <pkgroot>`; write `DEBIAN/control` (Package: mtls-hello, Version: from dub.json, Architecture: amd64, Depends: libc6, libssl3, openssl, Description from dub.json); write `DEBIAN/postinst` (generate self-signed cert at `/var/lib/mtls-hello/certs/...` if missing — CN=hostname, 10yr, key 0600 — mirroring feature 010 install.sh; never overwrite); `chmod 755 DEBIAN/postinst`; run `dpkg-deb --build <pkgroot> dist/mtls-hello_<version>_amd64.deb`.
- [X] T010 [US1] Add `package-debian` recipe to `justfile` — runs `bash scripts/package-debian.sh`.

**Checkpoint**: Debian package builds and installs cleanly on Debian.

---

## Phase 5: User Story 2 - Arch Package (Priority: P1)

**Goal**: `just package-arch` on an Arch host produces `dist/mtls-hello-<version>-1-x86_64.pkg.tar.zst`.

**Independent Test**: On Arch, `just package-arch` then `tar -I zstd -tf dist/*.pkg.tar.zst` lists `.PKGINFO`, `.INSTALL`, and the install tree.

### Implementation for User Story 2

- [X] T011 [US2] Create `scripts/package-arch.sh` — source `package-common.sh`; `stage_install_tree <pkgroot>`; write `.PKGINFO` (pkgname, pkgver=<version>-1, arch=x86_64, depend=openssl, pkgdesc from dub.json); write `.INSTALL` (generate self-signed cert at `/var/lib/mtls-hello/certs/...` if missing — same logic as Debian postinst); build with `tar -C <pkgroot> --owner=0 --group=0 -cf - . | zstd -o dist/mtls-hello-<version>-1-x86_64.pkg.tar.zst` (or `makepkg` if a PKGBUILD is preferred, but a direct tar+zstd is simpler and matches the data model).
- [X] T012 [US2] Add `package-arch` recipe to `justfile` — runs `bash scripts/package-arch.sh`.

**Checkpoint**: Arch package builds and installs cleanly on Arch.

---

## Phase 6: User Story 3 - Distro Detect & Dispatch (Priority: P2)

**Goal**: `just package` sniffs `/etc/os-release` and dispatches to the right native script.

**Independent Test**: Run `just package` on Debian → builds `.deb`; on Arch → builds `.pkg.tar.zst`; on unsupported → exits non-zero naming supported distros and suggesting `just package-docker`.

### Implementation for User Story 3

- [X] T013 [US3] Create `scripts/package.sh` — source `/etc/os-release` if present; if `ID` or `ID_LIKE` contains `debian` → exec `scripts/package-debian.sh`; if `ID` is `arch` → exec `scripts/package-arch.sh`; else exit 1 with `Error: unsupported distribution '<ID>'. Supported: debian, arch. Use 'just package-docker' to build both via Docker.`
- [X] T014 [US3] Add `package` recipe to `justfile` — runs `bash scripts/package.sh`.

**Checkpoint**: One command works on both supported distros.

---

## Phase 7: Polish & Cross-Cutting Concerns

- [X] T015 Add BATS test `@test "package.sh detects debian via /etc/os-release"` in `tests/smoke.bats` — stub `/etc/os-release` with `ID=debian`, run `scripts/package.sh` in a mode that only prints the detected distro (add a `--detect` flag that prints and exits), verify output is `debian`.
- [X] T016 [P] Add BATS test `@test "package.sh detects arch via /etc/os-release"` in `tests/smoke.bats` — same with `ID=arch`.
- [X] T017 [P] Add BATS test `@test "package.sh rejects unsupported distro"` in `tests/smoke.bats` — stub `ID=fedora`, verify exit non-zero and error mentions `package-docker`.
- [X] T018 Update `README.md` — add a "Building Packages" section with the four commands (`just package-docker`, `just package-debian`, `just package-arch`, `just package`) and install/remove instructions from quickstart.md.
- [X] T019 Run `just test` — confirm all tests pass (existing + new detection tests). Docker build tests are manual (require Docker daemon); document in README.

---

## Dependencies & Execution Order

### Phase Dependencies

- **Setup (Phase 1)**: No deps.
- **Foundational (Phase 2)**: T003 → T004 (T004 is part of T003, called out for clarity). BLOCKS all user stories.
- **US1 Debian (Phase 4)**: Depends on T003. T009 → T010.
- **US2 Arch (Phase 5)**: Depends on T003. T011 → T012. Parallel with US1 (different scripts).
- **US4 Docker (Phase 3)**: Depends on US1 (T009) and US2 (T011) — the Dockerfiles run the same packaging scripts inside containers. T005/T006 → T007 → T008.
- **US3 Detect (Phase 6)**: Depends on US1 and US2 (dispatches to them). T013 → T014.
- **Polish (Phase 7)**: Depends on all. T015-T017 parallel (independent test stubs).

### Practical build order (MVP first)

Although US4 is listed as Phase 3 (MVP), its Dockerfiles call the Debian/Arch scripts. So the real order is:
1. T003-T004 (common core)
2. T009-T010 (Debian script) + T011-T012 (Arch script) — parallel
3. T005-T008 (Docker wraps the above) → **MVP: `just package-docker`**
4. T013-T014 (detect & dispatch)
5. T015-T019 (polish)

### Parallel Opportunities

```
T009 (package-debian.sh) ─┐  US1/US2, different files
T011 (package-arch.sh)   ─┘

T015 (test: debian detect) ─┐
T016 (test: arch detect)   ─┤  polish tests, independent stubs
T017 (test: unsupported)   ─┘
```

---

## Implementation Strategy

### MVP: `just package-docker` (produces both packages on the dev machine)

1. Phase 1 (T001-T002) — setup
2. Phase 2 (T003-T004) — shared staging core
3. Phase 4 (T009-T010) + Phase 5 (T011-T012) — Debian + Arch scripts (parallel)
4. Phase 3 (T005-T008) — Docker wraps both → **MVP**
5. Phase 6 (T013-T014) — distro detect
6. Phase 7 (T015-T019) — polish, tests, docs

---

## Notes

- `package-common.sh` is sourced by both distro scripts and copied into both Docker images — single source of truth for the install tree layout.
- The systemd unit uses `/var/lib/mtls-hello` as the system-wide data dir (certs, handlers). The postinst/.INSTALL creates this dir and generates the cert. User-specific overrides (REPOS_ROOT, trust dirs) stay under `$HOME` via environment.
- The Arch package uses a direct `tar | zstd` pipeline rather than `makepkg`/PKGBUILD to avoid needing a build user and `makepkg.conf` — simpler inside a container.
- Docker tests are manual because they need a running Docker daemon; the BATS suite tests distro detection and (where feasible) package tree structure without Docker.
- `scripts/package.sh --detect` is a harmless addition that makes the detection logic testable without actually building.
