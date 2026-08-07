# mtls-hello

Mutual-TLS HTTP server with LAN multicast discovery and Git repository synchronization.

## Made with

- **D** — the core daemon is written in D, compiled with `ldc` / `dub`
- **vibe.d** — async HTTP framework and mTLS transport (via deimos OpenSSL bindings)
- **OpenSSL 3.x** — TLS layer for both the server and Apache `mod_ssl`
- **Apache httpd** — CGI reverse proxy, `mod_dav` drop-box, and `mod_ssl` termination
- **Bash** — handler scripts, install tooling, sync logic, and hook templates
- **Git** — bare-repository synchronization and bundle format
- **systemd (user units)** — service lifecycle, socket activation, and logging
- **UDP multicast** — LAN peer discovery (`239.255.42.42:4242`)
- **Nix** — reproducible dev shell with pinned OpenSSL (no flakes)
- **just** — task runner; all recipes auto-enter `nix-shell`
- **Robot Framework** — Apache/CGI end-to-end tests
- **Docker** — cross-distro package builds (`.deb` + `.pkg.tar.zst`)
- **NNCP** (optional) — async store-and-forward mesh; native `/nncp/receive/` endpoint


## Development Environment

Development happens inside a plain Nix shell (no flakes). Add the nixpkgs
channel if you haven't already:

```bash
nix-channel --add https://nixos.org/channels/nixpkgs-unstable nixpkgs
nix-channel --update
```

All `just` recipes enter `nix-shell` automatically, so you only need Nix and
`just` installed on the host. The shell provides a real OpenSSL 3.x toolchain;
this matters because the host on this machine ships LibreSSL, which is
ABI-incompatible with the deimos OpenSSL bindings used by vibe.d.

```bash
just build      # build the D discovery daemon
just test-d     # D unit tests
just robot      # Apache/CGI end-to-end tests (Robot Framework)
```

## Quick Start

```bash
just build
just install
just install-service

# edit the service to remove --no-multicast if you want discovery:
systemctl --user edit mtls-hello
systemctl --user daemon-reload
systemctl --user enable --now mtls-hello
```

### Checking Logs

```bash
# Follow the service log:
journalctl --user -u mtls-hello -f

# Last 50 lines:
journalctl --user -u mtls-hello -n 50

# Since last boot:
journalctl --user -u mtls-hello -b
```

## After Install — What You Can Do

### 1. Create Bare Repos

Everything syncs as **bare repositories** under a `REPOS_ROOT` directory. Repos are **auto-created** on the receiving side if missing — you only need to create them on one machine:

```bash
mkdir -p ~/sync-repos
# Create on one machine — the other side auto-creates on first sync:
git init --bare ~/sync-repos/my-project.git
```

**Linking an existing repo's `.git` as a bare repo:** you can symlink the `.git` directory of a regular working tree into `REPOS_ROOT`:

```bash
cd ~/my-project
git init .     # already a working repo
ln -s "$(pwd)/.git" ~/sync-repos/my-project.git
```

This works because `bundle.post.sh` fetches and updates refs directly — it never pushes. Two things to be aware of:

- **After a sync, your working tree is stale.** `refs/heads/main` was updated but your files still reflect the old commit. Run `git checkout main` (or `git reset --hard main`) to catch up.
- **Don't `git push` into it** from another client — or disable `receive.denyCurrentBranch` (`git config receive.denyCurrentBranch ignore`). Otherwise a push to the currently checked-out branch will be rejected.

Symlinks work too — you can organize repos elsewhere and link them in:

```bash
ln -s /srv/git/my-project.git ~/sync-repos/my-project.git
```

### 2. Exchange Certificates Between Machines

Each machine has a hostname and a self-signed client certificate. To trust a peer:

**On machine A** (after starting the server):

```bash
# Machine B connects and is captured in purgatory
# Check what was captured:
ls ~/.local/share/mtls-hello/purgatory/

# Trust B's certificate:
bash scripts/trust-host.sh <B-hostname> ~/.local/share/mtls-hello/purgatory/<B-hostname>.*.crt
```

**On machine B**, repeat the same process trusting A's certificate.

The trusted certificates live at `<trust-dir>/<hostname>.crt` and are looked up by the hostname announced over multicast.

### 3. Start With Discovery

```bash
HOST_NAME=alpha \
OUR_CERT="$HOME/.local/share/mtls-hello/identity/$(hostname).crt" \
OUR_KEY="$HOME/.local/share/mtls-hello/identity/$(hostname).key" \
REPOS_ROOT=~/sync-repos \
CALLBACK_SCRIPT="$HOME/.local/share/mtls-hello/scripts/on-discover.sh" \
mtls-hello \
  --data-dir="$HOME/.local/share/mtls-hello" \
  --trust-dir="$HOME/.local/share/mtls-hello/hosts" \
  --purgatory-dir="$HOME/.local/share/mtls-hello/purgatory"
```

### 4. Syncing Happens Automatically

When machine A discovers machine B on the LAN (via UDP multicast on `239.255.42.42:4242`):

```
A announces ----------> B receives
                         B spawns on-discover.sh
                         B bundles all its repos
                         B POSTs bundle to A
                         A applies the bundle
A spawns on-discover.sh
A bundles all its repos
A POSTs bundle to B
B applies the bundle
```

After this exchange, both sides have all of each other's branches, tags, and commit history.

### 5. How Branch Conflicts Are Handled

| Scenario | Result |
|---|---|
| One side ahead | Both fast-forward to the ahead side's HEAD |
| Both diverged | Both versions preserved — yours at `refs/heads/main`, theirs at `refs/remotes/<peer>/main` |
| Tag exists on both | Existing tag wins; sender's version available via peer namespace |
| Repo only on one side | Automatically created on the receiver (`git init --bare`), then all branches fetched |

Sync is **idempotent** — re-syncing the same state produces no changes.

### 6. Customize With Hooks

Hook templates are installed as `.new` files. Activate one:

```bash
cp ~/.local/share/mtls-hello/scripts/pre-push.sh.new \
   ~/.local/share/mtls-hello/scripts/pre-push.sh
chmod +x ~/.local/share/mtls-hello/scripts/pre-push.sh
```

Your activated hooks are **never overwritten** by `just install`. Re-running install only updates the `.new` templates.

### 7. Per-Host Drop-Box

A per-host file drop-box at `/drop/<hostname>/<rest>` served by Apache `mod_dav` on a loopback VirtualHost, fronted by an mTLS CGI proxy that enforces:

- **401 Unauthorized** if the client cert is not in the trust store.
- **403 Forbidden** if the URL prefix (`<hostname>`) does not match the verified client cert CN.

Each trusted host sees only its own `drop/<cn>/` directory. The `mod_dav` backend handles PUT/GET/HEAD/DELETE/MKCOL/COPY/MOVE/PROPFIND/OPTIONS natively — no custom bash handlers.

Client wrappers (`cli/mtls-*.sh`) derive the hostname prefix from the cert CN automatically:

```bash
# Drop a file
cli/mtls-drop.sh --cert alice.crt --key alice.key --cacert peer.crt \
    --server https://peer:8443 --source notes.txt

# Fetch it back
cli/mtls-fetch.sh --cert alice.crt --key alice.key --cacert peer.crt \
    --server https://peer:8443 --name notes.txt --out notes.txt

# List your box
cli/mtls-ls.sh --cert alice.crt --key alice.key --cacert peer.crt \
    --server https://peer:8443
```

See `specs/023-per-host-dropbox/contracts/client-cli.md` for the full wrapper contract.

### 8. Environment Variables

| Variable | Purpose | Default |
|---|---|---|
| `HOST_NAME` | Your machine's name on the LAN | `localhost` |
| `CALLBACK_SCRIPT` | Script spawned on peer discovery | *(required)* |
| `OUR_CERT` | Client cert for outgoing mTLS | *(none)* |
| `OUR_KEY` | Client key for outgoing mTLS | *(none)* |
| `REPOS_ROOT` | Directory of bare `.git` repos to sync | *(none)* |

### Directory Resolution

Directories are resolved independently, in the order listed per directory.
`DIR` below is the resolved data directory (see **data-dir**); it is the single
base value every other path is derived from.

##### tl;dr
 - data-dir (DIR).                      
     - trust (hosts/): --trust-dir → DIR/hosts → hosts
     - purgatory/: --purgatory-dir → DIR/purgatory → purgatory
     - identity/: DIR/identity/<hostname>.crt + DIR/identity/<hostname>.key
     - handlers/: DIR/handlers
     - scripts/: DIR/scripts (+ CALLBACK_SCRIPT env → DIR/scripts/on-discover.sh)
     - apache/: DIR/apache (httpd.conf, site.conf, error.log, access.log, httpd.pid, mime/mime.types)
     - spool/: DIR/spool/<repo>
     - repos/: REPOS_ROOT env → DIR/repos
     - ffdc/: DIR/ffdc
     - shared-memory sync state: /dev/shm/mtls-hello-sync/<hash-of-DIR>/sync-state/<peer-hostname>.txt              

#### data-dir

Base directory for all runtime state.

1. `--data-dir=DIR` flag.
2. Installed layout: `~/.local/share/mtls-hello` (created by `just install`).

Once resolved, `DIR` is substituted into every path below.

#### trust directory (`hosts/`)

Stores trusted peer certificates as `<hostname>.crt`.

1. `--trust-dir=DIR` flag.
2. `DIR/hosts` (derived from the resolved data directory).
3. `hosts` (fallback when no data directory is configured).

#### purgatory directory (`purgatory/`)

Quarantine for unknown peer certificates; files named `<hostname>.<fingerprint>.crt`.

1. `--purgatory-dir=DIR` flag.
2. `DIR/purgatory` (derived from the resolved data directory).
3. `purgatory` (fallback when no data directory is configured).

#### handlers directory (`handlers/`)

CGI endpoint scripts served by Apache.

1. `DIR/handlers` (derived from the resolved data directory).
2. Installed layout: `~/.local/share/mtls-hello/handlers` (populated by `just install`; symlink or point the data directory here).

Contains: `hello.get.sh`, `head.get.sh`, `spool.get.sh`, `bundle.post.sh`, `cert-echo.get.sh`.

#### scripts directory (`scripts/`)

Helper scripts: shared CGI utilities, trust evaluation, certificate capture, sync, and install tooling.

1. `DIR/scripts` (derived from the resolved data directory).
2. Installed layout: `~/.local/share/mtls-hello/scripts` (populated by `just install`).

Contains: `cgi-common.sh`, `cgi-trust.sh`, `log-capture.sh`, `on-discover.sh`, `sync-common.sh`, `sync-state.sh`, `merge-spool.sh`, `trust-host.sh`, `apache-config.sh`, `apache-port-helper.sh`, `pre-push.sh.new`.

The discovery callback script is resolved as:

1. `CALLBACK_SCRIPT` environment variable.
2. `DIR/scripts/on-discover.sh`.

#### apache directory (`apache/`)

Apache runtime files; generated by `scripts/apache-config.sh` at startup.

1. `DIR/apache` (derived from the resolved data directory).

Contains: `httpd.conf`, `site.conf`, `error.log`, `access.log`, `httpd.pid`, `mime/mime.types`.

#### spool directory (`spool/<repo>/`)

Incoming bundles awaiting an operator-invoked merge.

1. `DIR/spool/<repo>` (derived from the resolved data directory; created on first receive).

#### repositories directory (`repos/`)

Bare git repositories to sync.

1. `REPOS_ROOT` environment variable.
2. `DIR/repos` (derived from the resolved data directory).

#### identity directory (`identity/`)

Our own certificate and key; the certificate is the file shared with peers for trust.

1. `DIR/identity/<hostname>.crt` and `DIR/identity/<hostname>.key` (installed layout: `~/.local/share/mtls-hello/identity/...`).

Used as the server identity for Apache and as the outgoing mTLS client identity (`OUR_CERT` / `OUR_KEY`).

#### ffdc directory (`ffdc/`)

First-failure data capture for sync push errors (one file per repo+peer).

1. `DIR/ffdc` (derived from the resolved data directory).

#### shared-memory sync state

Per-peer repository refs-hash cache (RAM-backed, cleared on reboot).

1. `/dev/shm/mtls-hello-sync/<hash-of-DIR>/sync-state/<peer-hostname>.txt`, where `<hash-of-DIR>` is the first 16 hex chars of the SHA-256 of the canonical `DIR` path.

### CLI Flags

```
mtls-hello [port] [options]

  --data-dir=DIR        Base for all runtime dirs (hosts/, purgatory/, identity/, scripts/, handlers/, apache/, spool/, repos/, ffdc/)
  --trust-dir=DIR       Trusted peer certificates (default: <data-dir>/hosts, else hosts)
  --purgatory-dir=DIR   Quarantine for unknown peer certs (default: <data-dir>/purgatory, else purgatory)
  --no-multicast        Disable LAN discovery
  --multicast-group=IP  Discovery group (default: 239.255.42.42)
  --multicast-port=PORT Discovery port (default: 4242)
  --multicast-interval=SECONDS  Announce interval (default: 5)
  --version             Print version and exit
```

### Certificates

`just install` generates a self-signed identity certificate and key on the first
install if none exist (named after this machine's hostname):

```
~/.local/share/mtls-hello/identity/<hostname>.crt
~/.local/share/mtls-hello/identity/<hostname>.key
```

The certificate is the file you share with peers for trust; a peer stores it as
`<trust-dir>/<hostname>.crt`. Re-running `just install` never overwrites existing
certificates. A legacy `certs/` layout (from older installs) is migrated
automatically to the flat layout on install and at daemon startup.

There is no CA. Each machine has its own self-signed certificate. Trust is established by exchanging certificate fingerprints out-of-band (see [Exchange Certificates](#2-exchange-certificates-between-machines)).

For outgoing mTLS sync calls, the same self-signed certificate can be used as the client certificate by setting `OUR_CERT` and `OUR_KEY` to the paths above.

### Deploying

For target machines that do not have Guix, build a self-extracting installer on the dev machine:

```bash
just self-extract
# → mtls-hello-installer-<hash>-<date>[-dirty].sh
```

Copy the installer to the target and run:

```bash
scp mtls-hello-installer-*.sh user@target:
ssh user@target

bash mtls-hello-installer-*.sh install
bash mtls-hello-installer-*.sh install-service

systemctl --user daemon-reload
systemctl --user enable --now mtls-hello
```

The installer requires only `bash`, `openssl` (for certificate generation), and a 64-bit x86 Linux system. It embeds the compiled binary and all vendored libraries, so the target does not need Nix, a D compiler, or the vibe.d libraries.

### Building Native Distribution Packages

For deployment to Debian/Ubuntu or Arch Linux targets, build native packages from source — no Nix, no Docker required on the target.

**On any host with Docker (builds both packages):**

```bash
just package-docker
# → dist/mtls-hello_0.1.0_amd64.deb
# → dist/mtls-hello-0.1.0-1-x86_64.pkg.tar.zst
```

**On Debian/Ubuntu (builds .deb natively):**

```bash
sudo apt install ldc dub libssl-dev pkg-config
just package-debian
```

**On Arch (builds .pkg.tar.zst natively):**

```bash
sudo pacman -S ldc dub openssl pkgconf
just package-arch
```

**Auto-detect distro:**

```bash
just package
# Debian → builds .deb, Arch → builds .pkg.tar.zst, other → suggests package-docker
```

**Install on the target:**

```bash
# Debian:
sudo dpkg -i dist/mtls-hello_0.1.0_amd64.deb
# Arch:
sudo pacman -U dist/mtls-hello-0.1.0-1-x86_64.pkg.tar.zst

# Then:
systemctl --user daemon-reload
systemctl --user enable --now mtls-hello
```

The package installs the binary to `/usr/bin/mtls-hello`, handlers to `/usr/lib/mtls-hello/`, and a systemd user unit to `/usr/lib/systemd/user/mtls-hello.service`. A self-signed identity certificate is generated on first install at `/var/lib/mtls-hello/identity/`. User data (identity, repos, trust store) under `$HOME` is preserved on removal.

### Spool and Merge Workflow

Bundles received from peers are **spooled** (saved to disk) rather than
applied immediately. This prevents concurrent-access corruption and gives
the operator control over when repositories are updated.

**Spool directory**: `~/.local/share/mtls-hello/spool/<repo>/`

**Merge spooled bundles**:
```bash
bash ~/.local/share/mtls-hello/scripts/merge-spool.sh
# or merge a specific repo:
bash ~/.local/share/mtls-hello/scripts/merge-spool.sh laptops
```

The merge script applies all spooled bundles to the bare repositories,
promotes branches, and deletes the spool files on success. Bundles with
missing parent commits are skipped with a clear message.

## NNCP Integration (feature 025)

Feature 025 replaces the standalone `nncp-caller` daemon with a native
**POST `/nncp/receive/`** endpoint that pipes packets to `nncp-toss`
directly. A combined Ed25519 / X25519 keypair flows into both the mTLS
identity certificate and `<data-dir>/nncp.hjson`'s `self:` block — one
keygen, two identities. Discovery triggers an
`scripts/on-discovery.d/` directory chain (`00-validate`, `10-trust-add`,
`20-nncp-register`, `50-bundle-push`, `90-log`) that registers peers
into both our trust store and the NNCP neighbour table.

**Upstream install guidance** lives at
<http://www.nncpgo.org/Installation.html>. Distro packages exist for
Arch AUR, Debian, DragonFly BSD, FreeBSD, Guix, Linux Mint, NetBSD,
NixOS, Ubuntu, and Void Linux; upstreams's preference is to use the
distro package when available.

**For Tumbleweed-Slowroll hosts — the project's primary live-run host** —
no `zypper install nncp` path exists. `scripts/build-nncp.sh` therefore
builds from `/tmp/nncp-8.13.0` and follows upstream's
`-ldflags -X go.cypherpunks.su/nncp/v8.DefaultCfgPath=...` pattern so
`nncp-toss` / `nncp-call` fall back to per-install paths instead of
`/etc/nncp.hjson` + `/var/spool/nncp`. When a distro package *is* on
`PATH`, `build-nncp.sh` short-circuits to symlink alignment — we
respect upstream's "Possibly NNCP package already exists for your
distribution" recommendation.

The deviation rationale is documented at
`specs/025-nncp-replace/distro-policy.md`. The install script honours
three concrete upstream directives:
- **Go 1.22+ required**: `build-nncp.sh` aborts on earlier `go version`.
- **Tarball integrity verification**: looks for `*.sha256` /
  `*.sha256sum` / `SHA256SUMS` next to the source per upstream's
  "check its integrity and authenticity"; fails closed by default
  (overridable via `--no-integrity-check`).
- **`redo` build system**: tried first if `command -v redo` succeeds; falls
  back to plain `go build` only on hosts without `redo`.

