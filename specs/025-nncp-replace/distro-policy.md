# Distro Policy: build-from-source over distro-package, and why

**Purpose**: Document why feature 025 builds NNCP from the locally-extracted source tree at `/tmp/nncp-8.13.0` rather than installing an upstream distro-package. Distils the rationale surfaced by reading http://www.nncpgo.org/Installation.html and the prior shortcomings in `cw28d34` (`c2ccb2d004 feat(025): commit-marker-followup`).

**Created**: 2026-08-07

---

## Upstream recommendation (paraphrased)

The page at `nncpgo.org/Installation.html` opens with:

> Possibly NNCP package already exists for your distribution.
> [list of distro package paths: Arch AUR, Debian, Docker image,
>  DragonFly BSD ports, FreeBSD ports, Guix, Linux Mint, NetBSD,
>  NixOS packages, Ubuntu, Void Linux]

It then says NNCP needs Go 1.22+ and runs `redo build` from the upstream tarball, **after** the user has checked the tarball against the upstream-published SHA256SUMS / PGP signature. (We've quoted the spirit of `Installation.html` here, not the literal upstream text — the page is freely-distributed engineering documentation and lives at an authoritative URL.)

## Our deviation summary

| Step | Upstream guidance | Our impl | Rationale |
|---|---|---|---|
| Distribution package | Prefer distro package when available | Always build from `/tmp/nncp-8.13.0` | Tumbleweed-Slowroll (the project's primary live-run host) has **no `zypper install nncp`**. The user's distribution list confirms coverage for the distros we don't run. |
| Source archive | `tarballs/nncp-8.13.0.tar.xz` from upstream | Pre-extracted at `/tmp/nncp-8.13.0` (vendored) | The user supplied that tree at the start of the feature. Re-tarball-fetch + integrity verify pattern is documented in `scripts/build-nncp.sh`'s comments; absent `SHA256SUMS`, `build-nncp.sh` warns loudly and continues for dev environments, with a hard error for production paths. |
| Integrity check | **must** check tarball's `SHA256SUMS` / `PUBKEY-SSH.pub` / `PUBKEY-PGP.asc` against upstream | `build-nncp.sh` does look up `*.sha256 / *.sha256sum / SHA256SUMS` next to the source dir, and computes a canonical-listing hash of the *extracted* directory as informational output. | Without a tampered tarball bytes (we have the dir, not the tarball), we cannot byte-equal upstream's recorded sum — so this is informational. The user's contribution of `/tmp/nncp-8.13.0`-as-source is inferentially a trust delegation; a re-download of the upstream tarball + signed-sum check would close the gap for production. |
| Build system | `redo` (DJB's rebuild — `cr.yp.to/redo.html`) | `go build` with `-ldflags -X` matching `build-nncp.sh`'s defaults; `redo` is *attempted* if `command -v redo` succeeds AND a `.do` rule file is present at the source root | Tumbleweed-Slowroll doesn't ship `redo`. We detect it (parity with upstream) but fall back to `go build` rather than mandating an additional toolchain dep. |
| Go version | "Go compiler 1.22+" | Hard check: `build-nncp.sh` parses `go version`, compares against 1.22 via `sort -V`, aborts with "feature 025 aborts install on Go 1.21 or earlier" | Defends against accidental regressions on hosts that pre-date the Go 1.22 baseline. |
| Layout | `/usr/local/etc/nncp.hjson` / `/var/spool/nncp` / `/usr/local/bin/nncp-toss` | `$HOME/.local/share/mtls-hello/{nncp/nncp.hjson,nncp/queues,run/nncp,bin/}` | Per-user install — matches features 010 / 018 / 022 / 023's `*.local/share/mtls-hello` precedent. No `/etc`-tier writes; no systemd unit; no `/var`-tier spool — all of which are out-of-scope for a private "my laptop on the LAN" deployment. A `--system-wide` install mode is documented as a possible future extension in `specs/025-nncp-replace/quickstart.md` and could draw on NNCP's compile-time `DefaultCfgPath=/usr/local/etc/nncp.hjson` defaults if the user wants. |

## What we would change in feature 025 if we were to fully match upstream

In rough priority, were the user to express operational needs:

1. **Adopt distro packaging on supported hosts**: if a future feature (`026-distro-packaging` or similar) targets Debian/Ubuntu/Arch specifically, ship a `.deb` / `.pkg.tar.zst` that pulls `nncp-toss` from upstream distro repos and ABI-pins to our `nncp.hjson` schema version. Already partly covered by `feature 015-github-actions` (CI artifacts).
2. **Tarball + PGP integrity**: download `https://www.nncpgo.org/tarballs/nncp-8.13.0.tar.xz` plus `*.sha256.asc`; have `build-nncp.sh` `gpg --verify` against `PUBKEY-SSH.pub` (already in `/tmp/nncp-8.13.0/PUBKEY-SSH.pub`) and `sha256sum -c`. *Out-of-scope* for feature 025 since the user's source-only provenance is acceptable for our threat model.
3. **Adopt `redo`** by adding `cr.yp.to/redo/redo` to `nix-shell`'s `pkgs`, or vendoring DJB's redo. Marginal gain — `go build` is fine.
4. **System-wide install path (`--system-wide` flag)**: write to `/etc/nncp/nncp.hjson`, `/var/spool/nncp`, `/usr/bin/`, with systemd `--user` or system units; would move feature 025 from "private laptop on LAN" to "server-class deployment".

## Where this deviation is captured

- **Spec**: `specs/025-nncp-replace/spec.md` (Assumptions + Out of Scope sections reflect this).
- **Plan**: `specs/025-nncp-replace/plan.md` (Phase 0–5 explicitly note the per-user layout).
- **Contracts**: none — the deviation is whole-architecture, not contract-level.
- **README**: cross-references this file (single line in the NNCP section).
