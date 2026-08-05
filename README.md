# mtls-hello

Mutual-TLS HTTP server with LAN multicast discovery and Git repository synchronization.

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
OUR_CERT="$HOME/.local/share/mtls-hello/certs/certs/server.crt" \
OUR_KEY="$HOME/.local/share/mtls-hello/certs/private/server.key" \
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

### 7. Environment Variables

| Variable | Purpose | Default |
|---|---|---|
| `HOST_NAME` | Your machine's name on the LAN | `localhost` |
| `CALLBACK_SCRIPT` | Script spawned on peer discovery | *(required)* |
| `OUR_CERT` | Client cert for outgoing mTLS | *(none)* |
| `OUR_KEY` | Client key for outgoing mTLS | *(none)* |
| `REPOS_ROOT` | Directory of bare `.git` repos to sync | *(none)* |

### CLI Flags

```
mtls-hello [port] [cert] [key] [options]

  --data-dir=PATH       Base for handlers/ and scripts/ (default: none)
  --handlers-dir=PATH   Override handler script directory
  --trust-dir=PATH      Trusted peer certificates (default: certs/hosts)
  --purgatory-dir=PATH  Quarantine for unknown peer certs (default: certs/purgatory)
  --no-multicast        Disable LAN discovery
  --port=0              Random ephemeral port
  --port-file=PATH      Write chosen port to file
  --version             Print version and exit
```

### Certificates

`just install` generates a self-signed server certificate and key on the first install if none exist:

```
~/.local/share/mtls-hello/certs/certs/server.crt
~/.local/share/mtls-hello/certs/private/server.key
```

Re-running `just install` never overwrites existing certificates.

There is no CA. Each machine has its own self-signed certificate. Trust is established by exchanging certificate fingerprints out-of-band (see [Exchange Certificates](#2-exchange-certificates-between-machines)).

For outgoing mTLS sync calls, the same self-signed certificate can be used as the client certificate by setting `OUR_CERT` and `OUR_KEY` to the paths above.

### Deploying Without Guix

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

The installer requires only `bash`, `openssl` (for certificate generation), and a 64-bit x86 Linux system. It embeds the compiled binary and all vendored libraries, so the target does not need Guix, a D compiler, or the vibe.d libraries.

### Building Native Distribution Packages

For deployment to Debian/Ubuntu or Arch Linux targets, build native packages from source — no Guix, no Docker required on the target.

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

The package installs the binary to `/usr/bin/mtls-hello`, handlers to `/usr/lib/mtls-hello/`, and a systemd user unit to `/usr/lib/systemd/user/mtls-hello.service`. A self-signed certificate is generated on first install at `/var/lib/mtls-hello/certs/`. User data (certs, repos, trust store) under `$HOME` is preserved on removal.
