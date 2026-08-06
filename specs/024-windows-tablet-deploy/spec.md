# Feature Specification: Windows 11 / WSL Ultraportable Tablet Deployment

**Feature Branch**: `024-windows-tablet-deploy`

**Created**: 2026-08-06

**Status**: Draft

**Input**: User description:
> please make consideration about what way should we run our server on a Windows 11 with WSL. Should we go more WSL way and expect stability (and possibility to start with boot??), or should we go more tray-icon way. Note that it is going to be an ultraportable tablet

## Architectural Decision (the consideration)

Three serious deployment shapes were weighed for running our server on Windows 11 / WSL on an ultraportable tablet (Surface-class, often used in tablet mode, ARM64/x86, frequent sleep/wake, touch-first, keyboard rare).

### Option A — WSL2 systemd service only

Run the existing server (Apache+mod_dav+mTLS, no code change) as a systemd user unit inside WSL2, auto-started at WSL boot. Reach LAN peers at `:8443`.

| Pros | Cons |
|---|---|
| Stability: systemd handles restart on crash | Zero UI — server is invisible on a tablet |
| Pre-login: server is up before user logs in, so peers can drop files onto a "sleeping" tablet | Admin requires `wsl --exec …` — effectively SSH-like — needs a terminal, defeatsthe tablet form factor |
| Reuses every byte of feature 023 | WSL2 sleep/wake is known-fragile; gap during which peers can't reach the tablet |
| | Firewall / loopback port-forwarding between Windows and WSL2 needs care per host |

### Option B — Windows tray icon only

Run the server as a Windows native process with a tray icon (PowerShell+WPF or C#+WinForms), exposed as `:8443` on the Windows host.

| Pros | Cons |
|---|---|
| Touch-native: right-click menu is the right UX for a tablet | Tied to user logon — pre-login dead — peers can't drop on a sleeping tablet |
| Glanceable status | GUI app rebooted with the user session; tray icon can be killed independently of the server (or, worse, take the server with it if same process) |
| | Requires porting the server (D + Nix-shell) to Windows or wrapping WSLg — significant scope creep on a project that deliberately stays Linux-only |
| | Sleep/wake: GUI process lifecycle is unreliable across S0/S3 transitions |

### Option C — Hybrid (RECOMMENDED)

Use both, with deliberately decoupled lifecycles:

- **WSL2 systemd unit (truth + transport)**: Apache+mod_dav+mTLS runs inside WSL2 exactly as on Linux. Bound to `0.0.0.0:8443` inside the WSL2 VM; Windows-side portforwarding so LAN peers reach the tablet directly. A scheduled task at Windows boot fires `wsl --exec systemctl --user start mtls-hello.service` so the server is reachable **before** any user logs in. systemd-managed crash loop and restart.
- **Windows-native tray icon (visibility + control)**: a small Windows process launched via Run-key on user logon. Speaks to the WSL server over loopback-mTLS using the same `cli/mtls-*` wrappers we already ship. No data plane through the tray icon — it's a control plane only. Display: 4-state color (green/yellow/red/grey). Menu: status / open drop-box / pause discovery / resume discovery / view trusts / restart server / quit. "Quit" closes the tray only; server keeps running. "Restart server" shells out `wsl --exec …` and waits for green.
- **Decoupling**: tray dies → server stays up; server dies → tray shows red and offers "Restart server" → user taps → WSL unit restarted → tray turns green.

| Pros | Cons |
|---|---|
| Boot-time availability for LAN peers (no logon gate) | Two components to install / maintain |
| Touch-friendly admin (no keyboard) | IPC is `wsl --exec` over `cli/mtls-*` wrappers — extra hop, but uniform with how remote peers reach the server |
| Resilience to either-side death | WSL2 sleep/wake lag still a thing — handled by surfacing "degraded" yellow |
| Re-uses all existing infra (cli/mtls-*, scripts/install.sh, Apache+mod_dav, cameras-and-peers-style trust gate) | |
| Single architectural shape fits multiple device classes — the same plan scales from Surface Pro X (ARM64) to a Surface Laptop (x86) | |

**Recommendation**: Option C. Wins on every dimension the tablet form-factor cares about, and is the only option that doesn't force the user to choose between "peers can reach me pre-logon" and "I can admin the server without a keyboard". The added maintenance cost is small: tray icon is ~150 lines of PowerShell + native WinForms `NotifyIcon` (no NuGet deps, PowerShell 5.1 + .NET runtime bundled in Windows 11) and re-uses the existing CLI wrappers.

### Research validation (2026-08-06)

This recommendation was sanity-checked against a web research brief covering six topics: WSL2 networking, pre-login startup, sleep/wake, tray frameworks, touch UX, and ARM64 considerations. Key findings are captured in [`research.md`](./research.md). The architectural shape (hybrid: WSL systemd + Windows tray icon) was confirmed; substantive refinements were applied to FRs and Assumptions below. No architectural reversal — just sharper defaults.

---

## User Scenarios & Testing *(mandatory)*

### User Story 1 — Pre-login LAN drop box (Priority: P1)

A friend on the same LAN wants to drop a photo or a PDF onto the tablet while it's sitting screen-off on a couch. The tablet must accept the drop **without** the user having logged into Windows.

**Why this priority**: This is the "always-on drop target" promise. Without it, the ultraportable is just dead weight unless interacted with. Anything else can be deferred.

**Independent Test**: Reboot the Windows host cold. Wait 90 s. From a peer on the same LAN, run `curl --cert peer.crt --key peer.key --cacert server.crt -X PUT --data-binary @photo.jpg https://<tablet>:8443/drop/<tablet>/photo.jpg`. The PUT must return 201 / 204 / 207 depending on WebDAV semantics, and the file must exist on disk at `<data-dir>/drop/<tablet>/photo.jpg` after the request. Repeat at 30 s, 60 s, 90 s, 120 s intervals and assert 201 within the 90 s window.

**Acceptance Scenarios**:

1. **Given** the Windows host has just cold-booted and no user is logged in yet, **When** 90 s have elapsed since boot, **Then** a peer `curl --cert peercert --cacert servercert -X PUT` against `https://<tablet>:8443/drop/<tablet>/photo.jpg` returns 201 Created.
2. **Given** the server is alive inside WSL pre-logon, **When** the user subsequently logs in, **Then** the Windows tray icon appears in the system tray within 5 s of logon completing, displaying a green status.
3. **Given** the server is alive, **When** a peer does an OPTIONS / PROPFIND / GET request against the host's drop-box, **Then** it succeeds with the same HTTP semantics as on a Linux host (200 / 207 / Last-Modified / ETag / Accept-Ranges: bytes).

### User Story 2 — Glanceable tray health (Priority: P1)

The user, on a touch device with no immediate keyboard handy, sees the tray icon and can tell whether the server is alive. A red icon next to the clock is "I lost connectivity to peers"; a green icon is "all good". No need to type commands.

**Why this priority**: Without glanceable status the tablet UX is hostile — the user is forced to corroborate server status by trying a curl from another device, which is absurd on a handheld.

**Independent Test**: Cause the WSL service to crash (`systemctl --user kill mtls-hello.service`); within 30 s, the tray icon goes red and the menu shows "Restart server". Restore the service; within 15 s, the icon returns to green.

**Acceptance Scenarios**:

1. **Given** both server and tray icon are healthy, **When** the user glances at the tray icon, **Then** it appears in the colour-mapping (green / yellow / red / grey).
2. **Given** the tray icon is loaded, **When** the WSL server health endpoint (`GET /head`) fails twice in a row, **Then** the icon turns red within 30 s and the menu shows "Restart server".
3. **Given** the user has paused discovery, **When** the user glances at the tray icon, **Then** the icon is grey and the menu shows the current pause-resume timestamp.

### User Story 3 — Touch-friendly discovery pause / resume (Priority: P2)

The user is boarding a plane or moving to a coffee shop and wants to throttle multicast announcements without disabling the drop-box itself.

**Why this priority**: Multicast is noisy and battery-draining. Off-switch is a quality-of-life feature — not core, but expected quickly once the device's radio subsystem changes frequently.

**Independent Test**: With discovery on, observe multicast announcements via `tcpdump -i any udp port 5353 -c 5`. Tap "Pause discovery" in the tray menu. Within 5 s, multicast traffic from the host drops to zero. Tap "Resume discovery". Within 5 s, multicast traffic resumes.

**Acceptance Scenarios**:

1. **Given** discovery is broadcasting, **When** the user taps "Pause discovery" in the tray menu, **Then** `<data-dir>/run/discovery-paused` exists and the multicast daemon observes it within 5 s and stops broadcasting.
2. **Given** discovery is paused, **When** the user taps "Resume discovery", **Then** the flag file is removed and multicast broadcasts resume within 5 s.
3. **Given** discovery is paused, **When** a peer PUTs a file to the host's drop-box, **Then** the file is accepted (drop-box is unaffected by the discovery-paused flag).

### User Story 4 — Tap-to-restart on health failure (Priority: P2)

The tray icon shows red. The user taps "Restart server" without invoking any shell. Within ~15 s the icon turns green again.

**Why this priority**: WSL2 services crash occasionally on ultraportable hardware. The user should not have to ssh anywhere to bring the server back.

**Independent Test**: Stop the service, wait 15 s, tap "Restart server" in the tray menu, observe icon colour transition to green within 15 s and `systemctl --user is-active mtls-hello.service` returning `active` within 30 s.

**Acceptance Scenarios**:

1. **Given** the tray icon is red, **When** the user taps "Restart server", **Then** the icon transitions red → yellow → green within 15 s and the WSL `systemctl --user is-active mtls-hello.service` returns `active`.
2. **Given** a restart was triggered, **When** the recovery completes, **Then** the tray status text shows "Restarted <HH:MM:SS>" until the next state change.

### User Story 5 — Trust list quick view (Priority: P3)

A peer cert has been added via `cli/trust-host.sh` (or directly to `<trust_dir>/`); the user wants visual confirmation without invoking a shell.

**Why this priority**: Useful diagnostics; not core MVP.

**Independent Test**: Run `cli/trust-host.sh add peerX`. Within 10 s, open the tray menu "View trusts"; the list shows `peerX`.

**Acceptance Scenarios**:

1. **Given** a peer cert has been added to `<trust_dir>/`, **When** the user opens the tray menu "View trusts", **Then** the list includes the newly trusted peer.

### Edge Cases

- WSL itself not running (e.g., user disabled WSL): tray icon shows yellow with menu option "Start WSL" (executes `wsl --status`). Server unreachable.
- WSL running but systemd unit not installed (e.g., fresh WSL, `scripts/install.sh` not run): tray icon shows yellow with menu option "Install service" (executes `wsl --exec bash /opt/mtls-hello/install.sh`).
- Tablet is ARM64 (Surface Pro X): WSL2 abstracts the host ISA; the same built server image works on x86_64 and aarch64.
- LAN is down (Wi-Fi disconnected, peer lost): server keeps running on loopback mTLS; tray stays green; multicast silently no-ops.
- IPv6-only network: server still publishes on `[::]`; works.
- Server crashes mid-PUT: mod_dav returns 5xx; drop-proxy renders 5xx; tray stays green (this is the peer's fault, not ours).
- User logs out: server keeps running in WSL; tray icon disappears; tray comes back on next logon.
- Sleep/wake: WSL2 resumes uncleanly; tray icon detects the gap (server-side health check times out) and shows yellow "degraded"; user can tap "Restart server" to recover.
- Multiple Windows users on the same tablet: each user's tray icon talks to the same WSL server but authenticates with their own client cert (their own `<data-dir>/clients/<user>.crt`).
- Cert trust revocation while a peer is mid-PUT: PUT completes; subsequent attempts get 401 (gate decision per-connection, not per-request).
- Tab in "Battery saver" mode: WSL's VM continues to run; tray polls server at a relaxed cadence (60 s instead of 30 s) so the system isn't pinged too often.
- Task Scheduler pre-logon firing inconsistent on first cold-boot after install: smoke test in `install-wsl.sh` runs `wsl --exec systemctl --user is-active mtls-hello.service` 90 s after install and emits a non-suppressible toast if it fails; user can re-run the install or check `%ProgramData%\mtls-hello\tray.log`.
- Modern Standby repeatedly leaves WSL2 unreachable on the user's specific hardware: the install script offers an opt-in "Disable Windows Modern Standby for this host" toggle (writes `powercfg /hibernate off` and disables Sleep timers via the registry), documented as a power-user trade-off (substantial battery-life cost). Default off.
- Tray icon dragged into the Windows 11 overflow chevron on tablet posture: user must drag it back to the visible tray once, after which Windows persists the preference. Documented in the install summary; toast notifications (FR-015) cover the discoverability gap during the period when the tray icon is hidden.

---

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: An installer script (`scripts/install-wsl.sh` or extension of `scripts/install.sh`) provisions the server into WSL2 by re-using all existing installation steps: identity generation, Apache render, mod_dav config, drop-box layout, host trust-store.
- **FR-002**: A systemd **user** unit `mtls-hello.service` lives at `/etc/systemd/user/mtls-hello.service` (or `~/.config/systemd/user/…`) inside WSL2, auto-started at WSL boot via `systemctl --user enable mtls-hello.service`. The unit runs the existing `scripts/install-service.sh` startup logic.
  - The install script additionally ensures the **canonical 4-step pre-login recipe** is in place: `[boot] systemd=true` in `/etc/wsl.conf`; `sudo loginctl enable-linger $USER` for the WSL user (keeps user systemd manager alive pre-login); and a Windows-side Task Scheduler entry firing `wsl.exe -d <distro> -- sleep infinity` so the WSL VM stays up across logon/logout and so that WSL doesn't self-shutdown on terminal exit. The `systemctl --user enable --now mtls-hello.service` step is what actually wires the server into the boot lifecycle; each of the four steps is verified before the install reports success.
- **FR-003**: A Windows-side **Task Scheduler** entry titled "mtls-hello WSL pre-start" fires at Windows startup (no user logon required), executing `wsl.exe --exec /usr/bin/systemctl --user start mtls-hello.service` to ensure the server is reachable within 90 s of WSL boot regardless of whether any user has logged in. Created with `schtasks /create /tn "mtls-hello WSL pre-start" /tr "wsl.exe -d <distro> --exec /usr/bin/systemctl --user start mtls-hello.service" /sc onstart /ru SYSTEM /rl highest /f` (system-context, highest privileges). After creation, the install script runs a smoke test: waits 90 s, then asserts `wsl --exec systemctl --user is-active mtls-hello.service` returns `active`. On failure, the user is shown a one-shot Windows toast notification ("mtls-hello did not start at boot — see %ProgramData%\mtls-hello\tray.log for details") so they don't silently lose pre-login LAN-drop on first cold-boot after install.
- **FR-004 (primary — mirrored mode)**: The installer writes `%UserProfile%\.wslconfig` (current user, and at system level if `--all-users` is passed) with `networkingMode=mirrored` so the WSL2 VM shares the Windows host's network stack. With mirrored mode enabled, the server binding `0.0.0.0:8443` from inside WSL2 is reachable directly on the LAN at the host IP — no portproxy needed. The install also adds a Windows firewall inbound rule via `New-NetFirewallRule -DisplayName "mtls-hello" -Direction Inbound -Protocol TCP -LocalPort 8443 -Action Allow -Profile Any` with both IPv4 (`-LocalAddress Any`) and IPv6 (`-LocalAddress Any6`) — mirrored mode does **not** bypass Defender Firewall.
- **FR-004a (fallback for NAT-mode installs)**: If the installer detects that mirrored mode is not available (older Windows 11, or the host has `networkingMode=mirrored` explicitly disabled, or `--no-mirror` is passed), it falls back to `netsh interface portproxy add v4tov4 listenport=8443 listenaddress=0.0.0.0 connectport=8443 connectaddress=<wsl-ip>` plus a Windows Scheduled Task that updates the WSL2 VM IP on every resume from sleep (Power-Troubleshooter Event ID 1). Mirrored mode is strongly preferred; the fallback exists for users who hit the known mirror-mode regressions (VPN, dual Ethernet+Wi-Fi ARP issues — see `research.md` Topic 1).
- **FR-005**: A Windows tray icon implemented as a single PowerShell 5.1 script (`tray.ps1`) at `%LOCALAPPDATA%\mtls-hello\tray.ps1`, plus a Run-key entry at `HKCU\Software\Microsoft\Windows\CurrentVersion\Run\mtls-hello-tray` with value `powershell.exe -WindowStyle Hidden -ExecutionPolicy Bypass -File "%LOCALAPPDATA%\mtls-hello\tray.ps1"` that fires at user logon. The script uses native WinForms `NotifyIcon` (`Add-Type -AssemblyName System.Windows.Forms` then `New-Object System.Windows.Forms.NotifyIcon`) — no NuGet deps, no WPF XAML, no extra runtime. PowerShell 5.1 is the default Windows shell on every Windows 11 22H2+ build through 25H2+; PowerShell *2.0* (the legacy engine) was removed in 2025 (KB5065506) but 5.1 was not affected. WinForms `NotifyIcon` auto-re-registers with the taskbar on the `TaskbarCreated` notification after explorer.exe restarts, so sleep/wake / explorer-crash recovery is handled by the framework with no extra code in `tray.ps1`.
- **FR-006**: Tray icon polls the WSL server health endpoint every 30 s (60 s on battery saver), via `wsl --exec /home/<user>/.local/bin/mtls-head.sh https://127.0.0.1:8443/head <client-cert>` — reusing our existing `cli/mtls-head.sh` wrapper for loopback mTLS auth.
- **FR-007**: Tray icon displays one of four states (green = healthy / yellow = degraded or WSL-not-running / red = unreachable / grey = discovery-paused) using native icon assets bundled in the install.
- **FR-008**: Tray icon context menu: "Status: <text>" (read-only), "Open drop-box" (opens default browser to `https://<tablet-hostname>:8443/drop/<tablet-hostname>/`), "Pause discovery", "Resume discovery", "View trusts", "Restart server" (executes `wsl.exe -d <distro> --exec /usr/bin/systemctl --user restart mtls-hello.service`), "Show last toast again" (re-fires the most-recent Windows toast notification — useful when FR-015 fired but the icon was hidden in the overflow chevron), "Quit" (closes tray only; server keeps running). The "Restart server" handler waits synchronously up to 15 s for `systemctl --user is-active mtls-hello.service` to return `active`, transitioning the icon yellow → green as it recovers.
- **FR-009**: A discovery-paused flag file at `<data-dir>/run/discovery-paused` causes the daemon's multicast broadcaster to skip beacons; tray creates / removes the flag via `wsl --exec touch <path>` / `wsl --exec rm <path>`. The cli/mtls-* wrappers do not need to be aware of this.
- **FR-010**: One inside-WSL binary. WSL2's Linux VM is itself x86_64 *or* aarch64 (matching the host's WSL2 VM type) — it does **not** translate between the two. We ship one `linux-gnu` binary built native to the WSL2 distro in use, and that binary runs unchanged on both `x86_64-linux-gnu-wsl2` and `aarch64-linux-gnu-wsl2` VMs. There is **no Prism-style cross-architecture translation** happening here (Prism is for Windows-on-Arm running x86_64 Win32 binaries, which is irrelevant to WSL2's Linux VM). `scripts/install-wsl.sh` uses `gcc -dumpmachine` (or `dub --print-build-platform`) on the host to pick the arch-appropriate artifact when packaging, and the install ships a single artifact per distro/WSA-relationship.
- **FR-011**: The installer auto-detects the host ISA (x86_64 vs aarch64) using `wsl.exe --status` output or `[System.Environment]::Is64BitOperatingSystem` from PowerShell, and copies the matching binary into the WSL2 home directory.
- **FR-012**: All tray operations are **idempotent and reversible**: tray can be un-installed without affecting the WSL server; the WSL server can be re-installed standalone; either can recover from the other's death.
- **FR-013**: Tablet's hostname in the local DNS / DHCP should resolve to a stable IP so peers can address it directly. Falls back to IP literal if mDNS / netbios is unavailable.
- **FR-014**: All scripts executed by the tray icon must propagate stdout/stderr to a known log file (default `%ProgramData%\mtls-hello\tray.log`) for post-mortem. Logs are rotated by size.
- **FR-015 (toast on state change)**: The tray icon emits a Windows toast notification via Windows App SDK's `AppNotificationManager` (which works from unpackaged `.exe`/PowerShell scripts, no MSIX identity required) every time the icon transitions state (`green → yellow`, `yellow → red`, `red → green`, etc.) and on user actions (paused / resumed discovery, restarted server). This is the **secondary discoverable signal** for tablet-mode users who may not see the 16×16 tray pixel; it is the touch-first answer to "where is my server?". Toast actions link back into the tray menu — a "Tray icon: red → Restart server" toast has an action button that fires "Restart server" directly. The "Show last toast again" menu item in FR-008 re-fires the most-recent toast on demand (useful when the toast auto-dismissed and the user wants to see the state-change reason).

### Key Entities

- **Server process** (Linux / WSL2): Apache httpd + mod_ssl + mod_dav_fs, owned by a non-root user, systemd-managed; persists across reboots and user logouts. Bound to `*:8443` and `127.0.0.1:8444`.
- **Tray icon process** (Windows): a single-instance GUI app launched at user logon; does not own data plane; one per Windows user.
- **Trust store**: `<data-dir>/hosts/<cn>.crt` — unmodified from feature 023. Tray reads but does not write.
- **Discovery-paused flag**: `<data-dir>/run/discovery-paused` — empty file, presence / absence toggled by tray.
- **Health endpoint**: `GET /head` (already exists; treated as the heart-beat). Tray polls it.
- **Restart hook**: `wsl.exe --exec systemctl --user restart mtls-hello.service` — single string invoked by tray's "Restart server" menu item.

---

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001 (boot-time reachability)**: After a cold Windows boot, the server is reachable by LAN peers (mTLS over `*:8443`) within 90 s of `wsl.exe` registering the user's distro as "Running".
- **SC-002 (pre-login drop)**: Without any user logon after boot, at least one peer can succeed in `curl --cert peercert --cacert servercert -X PUT https://<tablet>:8443/drop/<tablet>/x` within 90 s of Windows boot completion.
- **SC-003 (icon / state binding)**: When the WSL server's `GET /head` returns non-200 twice in a row, the tray icon turns red within 30 s. When the same endpoint returns 200 again, the icon returns to green within 30 s.
- **SC-004 (touch-only operations)**: Each of: pause discovery, resume discovery, restart server, view trusts, open drop-box, quit — completes in ≤ 15 s with at most 2 finger taps (no keyboard).
- **SC-005 (decoupled failure)**: If the tray icon process is killed (`Stop-Process -Name tray -Force`), the WSL server keeps accepting requests uninterrupted (verified by curl PUT). If the WSL server crashes, the tray icon turns red within 30 s; tapping "Restart server" returns the icon to green within 15 s.
- **SC-006 (sleep/wake survival)**: After a Windows sleep of 60 s, an immediate wake, and a 5-min idle period, the tray icon returns to green within 30 s of wake, or surfaces a degraded yellow with a working tap-to-restart.
- **SC-007 (no install ceremony)**: A completely uninstalled Windows host with WSL2 enabled can be brought up by: (a) `wsl --exec bash /path/to/install.sh` then (b) double-clicking `%ProgramFiles%\mtls-hello\install-tray.ps1`. Total install time ≤ 5 minutes.

---

## Assumptions

- Hardware: Windows 11 22H2+, 4 GB RAM free for WSL2 (1.5 GB VM base + 1 GB server + 500 MB headroom). Both x86_64 (Surface Laptop / Pro) and aarch64 (Surface Pro X) supported.
- WSL2 enabled in Windows Features; `wsl.exe --update` to the latest kernel recommended but not required.
- The **canonical 4-step pre-login recipe** is what `scripts/install-wsl.sh` writes (FR-002 / FR-003): (1) Task Scheduler "At startup" entry running `wsl.exe -d <distro> -- sleep infinity` as SYSTEM with highest privileges, "Run whether user is logged on or not"; (2) `[boot] systemd=true` in `/etc/wsl.conf`; (3) `sudo loginctl enable-linger $USER`; (4) `systemctl --user enable --now mtls-hello.service`. Each step is verified before install reports success. This is the documented pattern across multiple 2025–2026 community headless setups but **Microsoft does not officially bless it**. We accept the position because SC-001/002 only require "works most of the time", and we surface failures via the toast described in FR-015.
- `systemd` is enabled inside WSL2 (`/etc/wsl.conf` with `[boot] systemd=true`). Documented and set by the install script.
- The existing `scripts/install.sh` works unchanged in WSL2 (we have validated end-to-end mod_dav PUT/GET/PROPFIND on Tumbleweed-Slowroll already; WSL2's Ubuntu 22.04 userland matches the same Apache+OpenSSL 3 lineage).
- **WSL2 sleep/wake robustness**: Microsoft has not shipped a systemic fix as of early 2026. GitHub issues `microsoft/WSL#14005`, `#14193`, `#14248` document the unrecoverable-zombie state in 24H2/25H2 with WSL 2.6.x. KB5074109 (Jan 2026) fixed a related VPN+mirrored regression but not sleep/wake. The spec's surface-failing-gracefully decision stands. `scripts/install-wsl.sh` writes the following **opt-in workarounds** to `%UserProfile%\.wslconfig` (default-on, can be disabled without re-installing; flag file at `%LOCALAPPDATA%\mtls-hello\wsl-workarounds.json`): `vmIdleTimeout=-1` (prevents WSL self-shutdown when terminal exits); a Windows Scheduled Task that fires `wsl --shutdown` whenever Power-Troubleshooter Event ID 1 (resume from sleep) is posted, then waits 5 s before the user can `wsl --exec …` again.
- **Tray framework choice**: PowerShell 5.1 + native WinForms `NotifyIcon` — no NuGet, no WPF, no extra runtime. PowerShell 5.1 is the default Windows shell on every Windows 11 22H2+ build through 25H2+; PowerShell *2.0* (the legacy engine) was removed in 2025 (KB5065506) but 5.1 was not. WinForms `NotifyIcon` auto-re-registers on the `TaskbarCreated` event after `explorer.exe` restarts, so no manual `Shell_NotifyIcon` re-handling is needed. Total tray icon footprint: ~30 KB of PowerShell + bundled icon assets.
- **Touch UX**: Windows 11 has no dedicated Tablet Mode (that was Windows 10). Tray icons are *not* inherently hidden in tablet posture but can be pushed into the overflow chevron by Windows 11's heuristics. KB5101684 (late July 2026) improved reliability of the system-tray area when the taskbar detects touch devices in tablet posture. We treat the overflow-chevron risk as a baseline limitation and lean on FR-015 (toasts) for the secondary discoverable signal. Tap-and-hold triggers the tray context menu on touch by default.
- **ARM64**: no aarch64-specific issues for Apache httpd, mod_dav_fs, or OpenSSL (mature, architecture-portable C codebases; Debian/Ubuntu aarch64 repos ship builds via `apt`). Microsoft's Prism emulation (Dec 2025 update) applies only to **Windows-on-Arm Win32 binaries** and does **not** affect WSL2's Linux-side VM — we run native aarch64 Linux inside WSL2. We do **not** need a separate arch build: one inside-WSL binary per distro.
- **Server stack versions**: Apache httpd 2.4.68+ (June 2026 — includes CVE-2026-24072 mitigation and 12 other security fixes) and OpenSSL 4.0+ (May 2026 — engine removal, SSLv3 removal; major version bump). `scripts/install-wsl.sh` lets the distro's package manager resolve (no manual pinning unless Debian security updates flag a regression). OpenSSL 4.0 is a deliberate major bump and is explicitly noted in the install summary so the user knows Apache+OpenSSL are running recent versions post-install.
- Multicast on the LAN is allowed (firewall / switches permit UDP 5353 to broadcast). Discovery-pause provides an off-switch if multicast is throttled.
- TLS: per feature 010, the server uses an ad-hoc self-signed identity cert; cert is generated lazily (`scripts/install.sh` step) and the trust store in WSL2 is at `~/.local/share/mtls-hello/identity/<cn>.{crt,key}`, `~/.local/share/mtls-hello/hosts/<peer>.crt` (per feature 022 flattened layout).
- The existing `cli/mtls-*.sh` wrappers are present and re-used unchanged as the IPC contract between tray and server.
- Windows-side firewall is opened for `:8443` (inbound, TCP) by the install script via `New-NetFirewallRule` — required even in mirrored mode (mirroring operates below the firewall layer; we add IPv4 + IPv6 rules because mirrored mode supports both).

---

## Out of Scope

- Windows 10 or older (Windows 10 is end-of-life October 2025; not worth supporting).
- WSL1 (legacy, no systemd, no x86_64 VM).
- Native Windows build of the server (we keep the server Linux-only; WSL2 is the supported path). Crossing this line would mean re-porting OpenSSL bindgen, libapr, etc., which is not the point.
- mDNS / Windows network-discovery advertisement (link-local `mtls-hello@<cn>` service). Deferred to a follow-up feature; for now peers use the tablet's hostname (or DHCP-reserved IP).
- Cellular networks. Multicast typically doesn't work on cellular.
- Touch-precision / Surface Pen support beyond tap-and-hold for the tray menu. Sloppy touch is acceptable; we don't push gestures harder than necessary.
- Power-management hooks beyond the basic "battery saver = 60 s poll" cadence. We don't engineer Windows Modern Standby.

---

## Dependencies

- Windows 11 host with WSL2 feature enabled.
- A WSL2 distro (Ubuntu 22.04+ or openSUSE Tumbleweed; either works — they both speak Apache+mod_dav+systemd).
- The existing project (this repo) — `scripts/install.sh`, `apache-site.conf.in`, `cli/mtls-*`, `handlers/drop-proxy.sh`, etc. (Features 010, 012, 023).
- A self-signed identity cert generation flow (already present in `scripts/gen_certs.sh` / install.sh).
- A "friendly" UI language for the tray (PowerShell+ WPF, or .NET 8 self-contained C# WinForms). Both ship their runtime in Windows 10/11 — no extra runtime install.
- Optionally `wsl --update` for the latest kernel (recommended but not required).
