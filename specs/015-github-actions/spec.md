# Feature Specification: GitHub Actions CI & Releases

**Feature Branch**: main (inline)

**Created**: 2026-08-05

**Status**: Draft

**Input**: GitHub Actions for verification (BATS tests, Docker package builds) and automated releases (Debian/Arch packages as release artifacts on tag push).

## User Scenarios & Testing *(mandatory)*

### User Story 1 - CI Verifies Every Push (Priority: P1)

Every push to `main` triggers a GitHub Actions workflow that builds the project in a container, runs the BATS end-to-end test suite, and reports pass/fail. The workflow does NOT replace local testing — `just test` remains the primary way to run tests during development. The CI is a gate for pull requests and a post-push validation.

**Why this priority**: Catches regressions introduced in commits pushed to the shared repository. The local test suite depends on the dev machine's Guix setup; CI provides a clean, reproducible environment.

**Independent Test**: Push a commit to main; the Actions tab shows a green checkmark for the "CI" workflow if all tests pass, or a red X with the failing test output.

**Acceptance Scenarios**:

1. **Given** a push to `main`, **When** the CI workflow runs, **Then** the BATS test suite executes and all passing tests are reported.
2. **Given** a pull request, **When** the CI workflow runs, **Then** the PR shows the test status and any failures block the merge.

---

### User Story 2 - Release Artifacts on Tag (Priority: P1)

When a version tag is pushed (e.g. `v0.1.4`), a separate workflow builds both the Debian and Arch packages via Docker and attaches them as release assets. The release notes are auto-generated from git history.

**Why this priority**: Manual package building and uploading is tedious. Automating it ensures each release has matching binary packages without human error.

**Independent Test**: Push a tag `v0.1.4`; the GitHub Releases page shows a release with `mtls-hello_0.1.4_amd64.deb` and `mtls-hello-0.1.4-1-x86_64.pkg.tar.zst` attached.

**Acceptance Scenarios**:

1. **Given** a tag `v*` is pushed, **When** the release workflow runs, **Then** both Debian and Arch packages are built and attached to a new GitHub Release.
2. **Given** the release is created, **When** a user downloads a package, **Then** it matches byte-for-byte with a locally-built package from the same commit.

---

### Edge Cases

- Docker Hub rate limits — the workflow caches Docker layers and uses GitHub's container registry for base images.
- Already-existing release — the workflow updates the existing release rather than creating a duplicate.
- Workflow failure — failed steps produce clear error messages in the Actions log; partial artifacts are not published.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: A CI workflow file at `.github/workflows/ci.yml` MUST run on every push to `main` and on every pull request.
- **FR-002**: The CI workflow MUST build the project using the project's own Docker containers (not Guix, matching how packages are built for distribution).
- **FR-003**: The CI workflow MUST run the full BATS test suite and report results.
- **FR-004**: A release workflow file at `.github/workflows/release.yml` MUST run on push of tags matching `v*`.
- **FR-005**: The release workflow MUST build both Debian and Arch packages using the project's Docker build infrastructure.
- **FR-006**: The release workflow MUST create or update a GitHub Release and attach both package files as assets.
- **FR-007**: The CI workflow MUST NOT require Guix or any host-specific toolchain — it uses Docker for all build and test steps.
- **FR-008**: Local testing (`just test`) MUST remain the primary development workflow; the CI is a gate, not a replacement.

### Key Entities

- **CI workflow (.github/workflows/ci.yml)**: Runs on push/PR. Builds in Docker, runs `just test`, reports results.
- **Release workflow (.github/workflows/release.yml)**: Runs on tag. Builds packages via Docker, creates GitHub Release with artifacts.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: A push to main completes the CI workflow in under 15 minutes (accounting for Docker image pulls and full test suite).
- **SC-002**: A tag push produces both `.deb` and `.pkg.tar.zst` artifacts attached to a GitHub Release within 20 minutes.
- **SC-003**: The CI workflow passes only when all BATS end-to-end tests pass.

## Assumptions

- The GitHub repository has access to Docker (GitHub Actions runners provide it by default).
- The project's Docker build infrastructure (`docker/Dockerfile.*`) is self-contained and works on any Linux host with Docker.
- Tags follow the format `v<version>` matching the version in `dub.json`.
- The release workflow reuses Docker image layers from the CI workflow via Docker caching.
