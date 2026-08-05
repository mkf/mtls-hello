# Research: Self-Extracting Portable Installer

## Decision: Base64 + tar.gz payload embedded after a marker line

**Decision**: The self-extracting script consists of a shell header (subcommand dispatch + extraction logic) followed by a `__PAYLOAD__` marker line, followed by base64-encoded gzipped tar data. Extraction uses `sed '1,/^__PAYLOAD__$/d' "$0" | base64 -d | tar xz`.

**Rationale**:
- **base64**: Available on every Linux system (coreutils). `uuencode`/`uudecode` is deprecated and not installed by default on Debian 12. `shar` is archaic. `xxd` requires vim-common.
- **tar.gz**: Standard archive format, single-file payload, one extraction step. `tar xz` works everywhere.
- **sed marker line**: Portable across all sed implementations (GNU, busybox, BSD). Avoids needing to know the line number.
- **`$0` for self-reference**: The script reads itself to extract the payload. This requires the script be saved as a file — pipe-to-bash is not supported.

**Alternatives considered**:
- **Multiple base64 blocks** (one per file) — more complex extraction logic, no benefit.
- **`tail -n +N`** — requires pre-computing the line number during build, fragile if the template changes.
- **`ar`/`tar` archive as the header** (like .deb packages) — requires `ar` which is not universal.

## Decision: Shell script template at `scripts/self-extract.in`, assembled in justfile

**Decision**: The script logic lives in `scripts/self-extract.in` (version-controlled, testable). The `just self-extract` recipe builds the binary, prepares the payload tarball, base64-encodes it, and concatenates the template + marker + payload.

**Rationale**:
- Template is standalone bash, independently testable with a test payload.
- justfile recipe handles git metadata (hash, date, dirty) and payload assembly.
- Clean separation: template logic vs. build-time assembly.

**Alternatives considered**:
- **Entire script generated in justfile** (with heredocs) — unreadable for 80+ lines of bash with functions.
- **C program that self-extracts** — unnecessary complexity; bash handles this perfectly.

## Decision: Filename dirty detection via `git status --porcelain`

**Decision**: Use `[ -n "$(git status --porcelain)" ]` to detect dirty state. Append `-dirty` suffix when unclean.

**Rationale**:
- `git status --porcelain` is empty when the tree is clean, outputs one line per changed file when dirty.
- More reliable than `git diff --quiet` which can be affected by cached state.
- Standard git porcelain output, stable across git versions.

**Alternatives considered**:
- `git describe --dirty` — adds `-dirty` to the most recent tag, but we don't use tags and it adds complex commit-count syntax.
- `git diff-index --quiet HEAD` — equivalent but harder to read.

## Decision: No glibc version check in the initial implementation

**Decision**: The self-extracting script does not check the target's glibc version. The operator discovers incompatibility when the binary fails to start (symbol errors in journal). A glibc check can be added later if needed.

**Rationale**:
- The binary is compiled against LDC 1.27 which links glibc 2.38 symbols. On Debian 11 (glibc 2.31), the binary may fail if it uses newer symbols. In practice, LDC targets a conservative baseline.
- `ldd --version` parsing is fragile across distributions.
- Adds complexity for an edge case (operators targeting pre-Debian-11 systems).

**Alternatives considered**:
- Check `ldd --version | head -1` and parse the version to warn if < 2.31 — doable but not essential for MVP.
- Statically link the binary — would eliminate the glibc concern entirely but requires static OpenSSL which is not available in Guix.
