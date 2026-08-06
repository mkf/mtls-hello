# Research: Windows 11 / WSL Ultraportable Tablet Deployment

**Purpose**: Capture the current-state (2025–2026) factual research that informed `spec.md` revisions for hybrid WSL2 + tray-icon deployment of the mtls-hello server on an ultraportable tablet form factor.
**Created**: 2026-08-06
**Feature**: [spec.md](./spec.md)
**Related**: [requirements.md](./checklists/requirements.md)

## Method

A web-search-capable research agent was asked six scoped questions. Findings below are the consolidated brief that came back. Where a finding shapes the spec, that shape is noted in §"Spec implications". Source URLs are kept verbatim from the brief; for production-critical decisions a human should spot-check the *non-Microsoft* sources before relying on them (see "Source verification" below).

---

## Topic 1 — WSL2 networking mode for LAN reachability

**Question**: Microsoft-recommended approach for making WSL2 services reachable from LAN peers.

### Findings

- `networkingMode=mirrored` (in `%UserProfile%\.wslconfig`) is now **Microsoft's recommended** networking mode on Windows 11 22H2+. `netsh interface portproxy` remains documented for NAT mode but is no longer preferred. Mirrored mode also gives IPv6 and better VPN compatibility.
- Known issues on ultraportable hardware at the time of brief (mid-2026):
  - VPN+mirrored regression fixed in **KB5074109 (Jan 2026)**; two related VPN issues (#13459, #13626) remain open.
  - Sleep/wake unrecoverable zombie states — see Topic 3.
  - ARP-resolution black hole after residual HKCU proxy settings (#40296, Apr 2026).
  - Broadcast storm on dual Ethernet+Wi-Fi (#13380, Aug 2025).
  - Random IPv6 disconnects when roaming on some Wi-Fi routers (workaround varies: disable IPv6 on the WSL virtual adapter — helper for some, not others).
- Windows firewall rules are **still required** in mirrored mode (mirroring operates below the firewall layer; Defender Firewall applies rules to WSL distros by default in modern builds, but explicit inbound `:8443` is still needed — IPv6 too).
- Multiple WSL2 distros on mirrored: no documented issue for *two light console distros* (Ubuntu + openSUSE). Normal port-conflict rules apply if both bind 8443. Caveat: enabling a desktop environment inside one distro can break networking for all distros; Docker Desktop's port-proxy can conflict.

### Spec implications

- **FR-004** rewritten: as primary path, write `%UserProfile%\.wslconfig` with `networkingMode=mirrored`. `netsh interface portproxy` retained as secondary path for users on NAT-mode installations. IPv6 inbound rule added explicitly.
- Spec assumptions explicitly note that mirrored mode + WSL2 sleep/wake fragility is the new normal — see Topic 3.

### Sources

- Microsoft Learn — WSL networking — https://learn.microsoft.com/en-us/windows/wsl/networking (2025)
- MicrosoftDocs/WSL DeepWiki — https://deepwiki.com/MicrosoftDocs/WSL/5-networking (June 2026)
- microsoft/WSL#14005, #14193, #14248 (Dec 2025 – Feb 2026)
- hy2k.dev — WSL2 mirrored networking — https://hy2k.dev/en/blog/2025/10-31-wsl2-mirrored-networking-dev-server/ (Oct 2025)

---

## Topic 2 — Pre-login WSL2 service startup via Task Scheduler

**Question**: Reliable way to start a systemd unit inside WSL2 *before* any user has logged into Windows.

### Findings

- **`wsl.exe` from Task Scheduler "At startup" CAN run pre-logon** but only with the right configuration: trigger "At startup", "Run whether user is logged on or not" checked, "Run with highest privileges" checked, run as SYSTEM (`schtasks /ru SYSTEM`). This is the documented pattern referenced by multiple 2025–2026 community headless setups (OpenClaw, Hermes, others).
- Microsoft does **not officially bless** this pattern; community reports of inconsistent behaviour persist. "At logon of any user" is more reliable; for our case the "At startup" approach is workable but must be tested on target hardware.
- `[boot] systemd=true` in `/etc/wsl.conf` is necessary but not sufficient — it makes systemd PID 1 *if* the distro is launched; nothing in Windows makes the distro launch.
- Canonical 4-step recipe used in the community:
  1. Task Scheduler "At startup" → `wsl.exe -d <distro> -- sleep infinity`
  2. `/etc/wsl.conf` → `[boot] systemd=true`
  3. `sudo loginctl enable-linger $USER` (keeps user systemd manager alive without login)
  4. systemd user service → `systemctl --user enable --now mtls-hello.service`

### Spec implications

- **FR-003** updated to a recipe-shaped requirement: install step writes both Task Scheduler entry AND ensures `systemd=true`, `loginctl enable-linger`, and `systemctl --user enable --now` are applied.
- **SC-001** unchanged: 90 s post-boot reachability remains the measurable bar.
- **Assumptions**: explicit point that Microsoft does not officially bless this pattern and that the spec accepts the community-tested recipe.
- **Edge cases** (+1 entry): Task Scheduler pre-logon firing inconsistent on first boot after a fresh install — install script does a smoke test (`wsl --exec systemctl --user is-active mtls-hello.service`) and reports failure to the user via a one-shot toast notification if the service didn't come up.

### Sources

- Microsoft Learn — systemd in WSL — https://learn.microsoft.com/en-us/windows/wsl/systemd (2025)
- OpenClaw Issue #31589 — https://github.com/openclaw/openclaw/issues/31589 (Mar 2026) *(non-Microsoft)*
- OpenClaw Windows docs — https://docs.openclaw.ai/platforms/windows (June 2026) *(non-Microsoft)*
- XDA — automating Windows with WSL — https://www.xda-developers.com/automate-windows-with-wsl-cron/ (May 2026)

---

## Topic 3 — WSL2 sleep/wake (Modern Standby / S0ix)

**Question**: Does WSL2 hold service availability after a 60 s sleep + immediate wake on the latest Windows 11 + WSL kernel?

### Findings

- **No, it is still poor in early 2026**. Hyper-V Wi-Fi Direct Virtual Adapter fails its power transition (Event ID 10317); WSL2 loses vsock communication; the VM appears "Running" but is unreachable. Multiple open GitHub issues (#14005, #14193, #14248) document this in 24H2/25H2 with WSL 2.6.x.
- **Microsoft has not shipped a systemic fix**. KB5074109 was about VPN+mirrored regression, not sleep/wake.
- Community workarounds that materially help:
  - `wsl --shutdown` triggered on wake (Power-Troubleshooter Event ID 1) — destroys and restarts the VM cleanly.
  - `vmIdleTimeout=-1` in `.wslconfig` — prevents WSL shutting down on terminal exit, but doesn't fix wake failure.
  - Some users report mirrored mode helps sleep/resume.
  - `powercfg /hibernate off` + disabling Sleep entirely — most reliable for a server role.
  - Keep a `sleep infinity` process running — tricks WSL into not shutting down when the launcher terminal exits.

### Spec implications

- **SC-006** (sleep/wake survival) keeps our "punt" decision: tray detects degraded, offers tap-to-restart. *Spec accepts that surface-failing gracefully is the right answer in 2026.*
- **Assumptions**: explicit list of the optional-but-recommended workarounds (vmIdleTimeout=-1, wsl --shutdown on wake via Event ID 1, `sleep infinity` running). These are written into `scripts/install-wsl.sh` as opt-in during install.
- **Edge cases** (+1 entry): for surfaces where Modern Standby consistently makes WSL2 unusable, the spec recommends the install script offers "Disable Modern Standby for this machine" as a documented power-user option (with explicit warning about battery life).

### Sources

- microsoft/WSL#14005, #14193, #14248 (Dec 2025 – Feb 2026)
- dodjango gist — sleep/wake analysis — https://gist.github.com/dodjango/545a8322b43697fb81f214fad245a263 (Dec 2025)
- private-labs.com — WSL2 network issues — https://private-labs.com/wsl2-network-issues-what-caused-them-and-how-i-actually-fixed-them/ (May 2026)

---

## Topic 4 — Tray-icon framework choice (lowest install footprint)

**Question**: Best framework for a Windows 11 tray icon: PowerShell+WPF, .NET 8 single-file, Tauri?

### Findings

| Dimension | PowerShell 5.1 + WinForms NotifyIcon | .NET 8/9 single-file WinForms | Tauri v2 |
|---|---|---|---|
| Runtime deps | Powershell 5.1 (default) + .NET runtime (bundled with PS) | .NET runtime (self-contained = 15–30 MB) | None — statically linked Rust binary |
| Binary size | ~500 KB (`.ps1`) | ~15–30 MB trimmed | ~5–8 MB |
| Sleep/wake resilience | `NotifyIcon` auto-re-registers | Auto via WinForms message loop | Manual via `Shell_NotifyIcon` re-registration on `TaskbarCreated` |
| Touch UX | Right-tap context menu (default WinForms) | Same | Same (`tao` API supports) |
| Build toolchain | Text editor | Needs .NET SDK | Needs Node + Rust (build only) |
| Maturity | Mature | Most mainstream | Stable since v2 (2024+, growing) |

- The `Hardcodet.NotifyIcon.Wpf` WPF NuGet package adds a layered tray-icon-XAML abstraction; native `NotifyIcon` from `System.Windows.Forms` is simpler for a control-only tray (status, menu, no embedded panes).
- **PowerShell 5.1 is still the default Windows shell.** PowerShell *2.0* (the legacy engine) was removed in August 2025 (KB5065506 / Windows 11 24H2), but 5.1 is intact and present on every standard Windows 11 install through 25H2+.

### Spec implications

- **Assumptions**: pin PowerShell 5.1 + native WinForms `NotifyIcon` as the chosen path. (We dropped the generic "PowerShell+WPF" wording because the concrete answer is `"NotifyIcon"` from `System.Windows.Forms` — no NuGet deps, no WPF XAML needed for a control-only tray.)
- **FR-005** + **FR-008**: tray icon and its menu are PowerShell + `Add-Type -AssemblyName System.Windows.Forms` + `NotifyIcon`. Menu items are click handlers that shell out to `wsl.exe --exec …`.
- No new FRs (the change is wording-tightening, not behavioural).

### Sources

- KomuraSoft — Windows tray icon + toast guide — https://comcomponent.com/en/blog/windows-tray-icon-toast-notification-guide/ (July 2026) *(third-party)*
- Microsoft Support — PowerShell 2.0 removal — https://support.microsoft.com/en-au/topic/powershell-2-0-removal-from-windows-fe6d1edc-2ed2-4c33-b297-afe82a64200a (Aug 2025)

---

## Topic 5 — Touch-first tray UX on Windows 11

**Question**: How does the System Tray behave in Windows 11 tablet mode, and what's the modern replacement if it's broken?

### Findings

- Windows 11 has **no dedicated Tablet Mode** (that was Windows 10). The tablet-optimised taskbar applies automatically based on posture; tray icons are not *inherently* hidden but can still be pushed into the overflow chevron by Windows 11's icon-visibility heuristics.
- **KB5101684 (late July 2026)** improved "reliability of loading the system tray area when using the taskbar on touch devices in a tablet posture" — Microsoft acknowledged reliability issues here.
- No API pins a tray icon into the visible tray; user must drag from the overflow chevron.
- **Tap-and-hold triggers the right-click context menu** on tray icons by default — good for touch.
- Standard tray icon is ~16×16 px — very small on touch. **Modern secondary surface: Toast notifications via Windows App SDK's `AppNotificationManager`** — works from unpackaged .exes; no MSIX identity needed.
- WinUI 3 still has no first-party tray support; the `WinuiTrayIcon` NuGet package adds it but pulls in the Windows App SDK redist (~10 MB). The classic tray icon remains the lowest-complexity reliable path.

### Spec implications

- **New FR-015**: tray emits a Windows toast on every state change (`green → yellow → red → grey` transitions) — provides a discoverable signal on a tablet where the 16×16 icon is easy to miss.
- **FR-008** menu gains an item: "Show last toast again" for state-quiet moments.
- **Assumptions**: tablet-vs-desktop posture detection is left to Windows 11's auto-collapsing taskbar; we don't add our own posture heuristics.

### Sources

- KomuraSoft (same as Topic 4)
- KB5101684 (late July 2026) — referenced in Microsoft support docs

---

## Topic 6 — ARM64 (aarch64) considerations for our stack in WSL2

**Question**: Any aarch64-specific issues for Apache, mod_dav_fs, OpenSSL 3.x — including Prism emulation for Windows-on-Arm binaries?

### Findings

- **No aarch64-specific issues** identified for Apache httpd, mod_dav_fs, OpenSSL 3.x — these are mature architecture-portable C codebases with full aarch64 support. Debian/Ubuntu aarch64 repos ship right builds via `apt`. DAVLockDB uses portable `flock`/`fcntl` — identical on aarch64.
- **Microsoft Prism emulation updates (Dec 2025)** apply *only* to **Windows-on-Arm running x86_64 Win32 binaries**. They do *not* affect WSL2's aarch64 Linux VM — WSL2 does not do binary translation inside the VM. Our Apache + mod_dav + OpenSSL run native aarch64 Linux code, unimpacted by Prism changes.
- Recent security releases worth tracking (none architecture-specific):
  - Apache 2.4.66 (Dec 2025)
  - Apache 2.4.67 (May 2026) — CVE-2026-49975 mod_http2 DoS
  - Apache 2.4.68 (June 2026) — 13 fixes, including CVE-2026-24072 (.htaccess read)
  - OpenSSL 4.0.0 (May 2026) — major version (engine removal, SSLv3 removal)

### Spec implications

- **FR-010** tightened: single binary built once for `x86_64-linux-gnu-wsl2` runs unchanged on `aarch64-linux-gnu-wsl2` because both run inside WSL2's VM (no Windows-side binary translation involved). The "build twice" version of FR-010 (which we had in the original spec) was overly cautious — WSL2 itself abstracts the host ISA.
- **Assumptions**: confirm Apache 2.4.x ≥ 2.4.68 + OpenSSL ≥ 4.0.0 (or whatever the install script resolves via the system package manager at install time).

### Sources

- Windows Community Blog — Prism update — https://techcommunity.microsoft.com/blog/windowsosplatform/windows-on-arm-runs-more-apps-and-games-with-new-prism-update/4475631 (Dec 2025)
- Apache 2.4.68 release notes — https://cybersecuritynews.com/apache-http-server-2-4-68/ (June 2026)
- OpenSSL 4.0 upgrade guide — https://www.firedaemon.com/post/openssl-4-0-upgrade (May 2026) *(third-party)*

---

## Source verification

For a hobby / personal project, the brief is good enough. For anything that affects a *production* deployment, a human should:

- Spot-check the **alphabet-named secondary sources** (deepwiki.com, github.com/openclaw/, fire-daemon, hy2k.dev, dodjango gist, komura-soft, private-labs.com) — they may be real, but their editorial authority is harder to verify than the Microsoft Learn / KB / github.com/microsoft/WSL primary sources. The spec wording is intentionally conservative enough that none of the alphabet sources alone is load-bearing.
- Confirm **KB numbers and dates** (KB5074109, KB5101684, KB5065506) against a current Windows release-notes index before they're quoted in user-facing docs.
- Confirm **OpenSSL 4.0** timing if `scripts/install.sh` will need an Zypper/Apt pinning — the brief says "May 2026" but version-pinning is a per-distro decision; we leave that to the install script.

For this research.md, I am recording the URLs *as given by the brief* and not silently dropping any. None of the alphabet sources alone determines a spec requirement; the Microsoft Learn / WSL GitHub-issue sources are the load-bearing ones.
