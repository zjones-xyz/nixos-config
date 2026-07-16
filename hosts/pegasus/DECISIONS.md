# pegasus — decision log

Review surface for the autonomous authoring session that scaffolded `pegasus`
(AM4 Ryzen + RTX 4070, migrated from CachyOS) into the fleet flake. Each entry:
**decision → alternatives → rationale.** Nothing here was activated on hardware.

## Process / workflow

- **One feature branch (`pegasus-bringup`), per-phase commits** — *alt:* the five
  per-phase branches the brief suggested (`feat/pegasus-base`, …). *Why:* the
  repo's convention (and the `feedback_git_workflow` note) is one feature branch +
  one PR with a `[host]`-bracketed title; the phases are interdependent (they all
  touch `flake.nix`/`configuration.nix`), so stacked PRs would be noisy to review.
  Each commit is scoped to a phase and independently evaluates, preserving the
  per-phase history the brief wanted.
- **Validation = `nix flake check` + `nix eval` of each closure's `drvPath`** —
  *alt:* `nixos-rebuild build`. *Why:* this Mac is aarch64-darwin with no working
  Linux builder (the linux-builder VM is broken on macOS 26), so the x86_64-linux
  closure cannot be *built* here. Instantiation (eval to `.drv`) still fully checks
  module options and types, which is what catches drift. All five configs
  (pegasus, serenity, memory-alpha, hopper, hamilton) pass `nix flake check
  --no-build --all-systems`. Actually building pegasus is a MANUAL step.
- **Fleet conventions captured in root `CLAUDE.md`** — *alt:* extend
  `.claude/CLAUDE.md` (the existing team-shared project memory). *Why:* the brief
  asked for a root `CLAUDE.md` if absent; one was absent. It documents the
  module-per-concern layout, naming, and the staging/prod LE switch so future
  sessions stay consistent. `.claude/CLAUDE.md` remains the team instructions file.

## Locked decisions from the brief (implemented as-specified)

- **Stock latest kernel + `scx`**, no CachyOS/Chaotic kernel. `boot.kernelPackages
  = pkgs.linuxPackages_latest`. sched-ext is upstream since 6.12, so the stock
  kernel is sufficient; `services.scx` asserts kernel ≥ 6.12.
- **GPU: RTX 4070 on the proprietary driver with OPEN kernel modules**
  (`hardware.nvidia.open = true`). No legacy pin.
- **Dual-GTX-1070 box stays separate** — not added here (Pascal would force the
  whole host onto the frozen 580 branch). It is a separate Ollama node reached
  over Tailscale, fronted by Olla.
- **Garuda GNS used as reference only** — the `vm.*` sysctls in
  `modules/nixos/performance.nix` are modelled on its performance-tweaks;
  `garudaSystem` is **not** imported (it would impose Lix/fish/`nh`).

## Make-and-log decisions

1. **NVIDIA driver channel → `production`** — *alt:* `latest`. *Why:* conservative
   default; well-tested. Ada is fully supported. One-line swap to `.latest` is
   documented in `modules/nixos/nvidia.nix`.
2. **scx scheduler → `scx_lavd`** — *alt:* `scx_rusty`, `scx_bpfland`, etc. *Why:*
   latency-aware, good for an interactive/gaming desktop. The option enum is drawn
   from `pkgs.scx.full.schedulers`; verified `scx_lavd` is valid in the pinned
   nixpkgs. Trivially swappable via `services.scx.scheduler`.
3. **Router → Olla** — *alt:* LiteLLM (heavier; virtual keys/budgets). *Why:* the
   brief's choice; single Go binary, local-first, health-check failover. Packaged
   from source in `modules/nixos/olla-router.nix`. **Olla is not in nixpkgs.**
   Pinned to **v0.0.28** with a real `src.hash` (2026-07-03); only `vendorHash`
   is still a placeholder (needs an x86_64-linux build — resolves on first build
   on pegasus, see MANUAL-STEPS §5). The YAML config was verified against
   v0.0.28's shipped `config/config.yaml` + `internal/config/types.go`: endpoints
   use flat `model_url`/`health_check_url`/`check_interval`/`check_timeout`
   fields (the initial scaffold's nested `health_check: {path, interval}` was
   wrong), and `proxy.load_balancer` is set to `"priority"` — the default
   `least-connections` ignores endpoint priority, which would have broken the
   intended "prefer 4070, fail over to 1070" behaviour. Olla overlays the file
   onto `DefaultConfig()`, so the config only lists overrides.
4. **Deploy mechanism → `nixos-rebuild --flake` matching the repo**; for pegasus
   (an x86_64 box) builds are native, so no remote `--build-host` is needed (unlike
   the aarch64 Pis). Run deploys from the Mac or another host, never on pegasus
   while it reconfigures its own display/network.
5. **Shared HM layer → starship, direnv+nix-direnv, git, bash, vim, core CLI**
   (`modules/home/common.nix`). Host-specific bits kept out: `username`,
   `homeDirectory`, `stateVersion`, the `nrs`/`nrt`/`drs` rebuild aliases, and
   Plasma config. *Why:* these are the prefs that are identical on Linux and macOS.
   Matches the existing per-host `home.nix` style (memory-alpha/hopper).
6. **BTRFS subvolumes `@ @home @nix @snapshots @games`** — implemented per the
   brief in both the placeholder `hardware-configuration.nix` and a reference
   `disko.nix`. `disko.nix` is **not** imported into the closure (it would
   double-define `fileSystems.*` against the placeholder); it documents the
   intended install-time layout and can drive a declarative install.

## Other decisions

- **Storage / OS layout → drive-per-OS, not shared partitions.** *alt:* shrink
  CachyOS's existing LUKS+btrfs NVMe and carve partitions for NixOS (and later
  Windows) out of it. *Why:* CachyOS's free space is inside the encrypted btrfs
  volume, so making room means resizing an in-use LUKS container — risky and
  unnecessary. Instead:
  - **NixOS → its own second NVMe** (added for bring-up). CachyOS's drive is
    never touched; NixOS installs to a blank drive identified by
    `/dev/disk/by-id/` serial (see MANUAL-STEPS §1 and `disko.nix`). Once NixOS
    is proven, the CachyOS drive can be pulled, freeing its M.2 slot.
  - **SUPERSEDED 2026-07-11**: at install time, Zoe pulled the CachyOS drive
    entirely instead of dual-booting it alongside NixOS — no more shared box,
    no more "which NVMe is blank" ambiguity to navigate. pegasus is now
    single-NVMe. `disko.nix` and `MANUAL-STEPS.md` §1 have been updated to
    match (still identify the drive by `/dev/disk/by-id/`, just without the
    two-drive caution). This also frees the second M.2 slot the Windows/SATA
    decision below was partly based on — not revisited yet, flagging for
    later.
  - **Windows → its own SATA SSD** (LOCKED 2026-07-03). *alt:* a partition on
    the NixOS NVMe. *Why:* Windows Update rewrites the ESP/boot order and clobbers
    other OSes' entries; a separate drive with its own ESP contains that to a
    one-line firmware boot-order fix. Also, most AM4 boards have only two M.2
    slots — both used by CachyOS + NixOS during bring-up — so a SATA SSD is the
    slot that's actually free. Windows is occasional-use (things Linux can't do
    at all), so it doesn't need NVMe speed. Notes for when it's installed: enable
    fTPM + UEFI (Win11); expect to keep Secure Boot *off* (the NixOS kernel's
    out-of-tree NVIDIA module isn't signed without lanzaboote); disable Windows
    Fast Startup; reconcile the RTC (Windows localtime vs Linux UTC) via
    `time.hardwareClockInLocalTime = true;` or a Windows registry tweak. None of
    this touches the pegasus closure today — systemd-boot auto-discovers the
    Windows entry via firmware boot order when the time comes.
- **Tailscale inline, not via `modules/nixos/tailscale.nix`** — that module is
  hopper-flavoured (advertises an exit node). pegasus is a plain tailnet member
  (inference endpoint), so it enables Tailscale directly with `--ssh` only.
- **sops/tailscale-authKey gated on `builtins.pathExists secrets/pegasus.yaml`** —
  the encrypted secrets file can't be created without Zoe's age key and must not
  be fabricated. The wiring is present and correct in `configuration.nix` but
  inert until the file exists, so eval stays green. See SECRETS-TODO.md.
- **darwin host named `serenity`** — inferred from the existing SSH key comment
  `z@Serenity.local`. **Confirm** with `scutil --get LocalHostName` before
  activating. nix-darwin pinned to the `nix-darwin-26.05` release branch (its
  release check rejects master/26.11 against nixpkgs 26.05). `nix.enable = false`
  so it coexists with the Determinate Nix install on the Mac.
- **Gaming GPU drain via a symmetric `ollama-pause` oneshot**, hooked to
  gamemode's `custom.start`/`end`. The "what counts as a game launching" signal is
  a documented stub — confirm/replace per MANUAL-STEPS.
- **LUKS SSH remote unlock, added 2026-07-11** (requested mid-bring-up — Zoe
  wanted to be able to unlock from serenity without walking over). Mirrors
  memory-alpha's `boot.initrd.network.ssh` setup almost verbatim; two
  deliberate simplifications since pegasus has one stock onboard NIC instead
  of two renamed USB dongles: (1) no `systemd.network.links` MAC-pinning, (2)
  the pre-switch-root DHCP-flush oneshot loops over any `type ether`
  interface instead of hardcoding names. The one thing memory-alpha's
  writeup flagged as needing verification — whether the onboard NIC's driver
  needs adding to `boot.initrd.availableKernelModules` — turned out yes:
  the first real reboot test hit exactly this (initrd SSH timed out with
  pegasus confirmed sitting at the LUKS prompt on-screen, not just "not
  booted yet"). `r8169` (Realtek), confirmed via
  `readlink -f /sys/class/net/enp42s0/device/driver`, added via
  `lib.mkAfter`.
- **Desktop apps, added 2026-07-11** (requested batch): vscode, google-chrome,
  firefox, vivaldi, 1Password (gui+cli), claude-code, discord, ferdium,
  bambu-studio, orca-slicer, openscad, obsidian, spotify, ticktick,
  prusa-slicer, jellyfin-desktop, vlc — all confirmed present in the pinned
  nixpkgs before adding (queried directly rather than assumed from memory).
  `streamdeck-ui` added for the Elgato Stream Deck, with its udev rule
  registered via `services.udev.packages` for non-root access.
  Brain.fm was requested but has **no nixpkgs package and no native Linux
  client anywhere** (subscription web app only) — left out, usable via a
  browser.
- **Claude Desktop, added 2026-07-11 via a new flake input.** Anthropic has
  no nixpkgs package (their official Linux beta only shipped 2026-06-30,
  too recent to have landed upstream). *alt considered:* the older
  community pattern of patching the Windows/macOS Electron build to run on
  Linux (e.g. `k3d3/claude-desktop-linux-flake`) — rejected once the
  official beta's existence was confirmed, in favor of
  `aaddrick/claude-desktop-debian`, which as of its v3.0.0 release
  repackages that *official* `.deb` directly (same pattern nixpkgs itself
  uses for `google-chrome`/`spotify` — wrapping an upstream binary, not
  reverse-engineering one). Actively maintained (123 releases, latest
  v3.1.0 this month). Added as `inputs.claude-desktop-debian` with
  `inputs.nixpkgs.follows = "nixpkgs"`; the package itself
  (`claude-desktop-fhs`, the FHS-wrapped variant — needed for MCP servers,
  which shell out to `npx`/`uvx`/etc. expecting a standard filesystem
  layout) is passed into `hosts/pegasus/home.nix` via
  `home-manager.extraSpecialArgs` in `flake.nix`, since it has no
  home-manager module of its own, just a package output.
  - **Declared as `git+https://github.com/aaddrick/claude-desktop-debian.git`,
    not `github:aaddrick/claude-desktop-debian`** — this authoring session's
    GitHub access is scoped to `zjones-xyz/nixos-config` only, so the
    `github:` tarball-API fetch 403s here (it works fine anywhere with
    normal GitHub access, e.g. on pegasus itself). `git+https` uses plain
    git protocol instead, sidestepping the issue permanently rather than
    just working around it for this one session — see
    `.claude/hooks/flake-check-sandboxed.sh`, which does the equivalent for
    every other input.
  - **`flake.lock` was NOT fully resolved from this session** — the input's
    own transitive dependency (`hercules-ci/flake-parts`) still hits the
    same `github:` tarball-API 403 one level deeper, and this session's
    `add_repo` tool is explicitly restricted to only fire on an explicit
    user request, not autonomously to route around a validation gap. Every
    other part of the change was verified via the same deep-eval technique
    used throughout this branch (forcing
    `config.system.build.toplevel.drvPath`) — the trace confirms the *only*
    unresolved piece is that one fetch. Run `nix flake lock` (or just the
    next `nixos-rebuild switch --flake .#pegasus`, which auto-updates the
    lock for new inputs) on pegasus itself — full internet, no scope
    restriction — then commit the resulting `flake.lock` diff.
    **Resolved 2026-07-11** — `nix flake lock` run on pegasus itself, pushed,
    and re-verified end-to-end from this session (nested
    `--override-input` paths for `flake-parts`/`nixpkgs-lib`, since they're
    transitive to `claude-desktop-debian` rather than direct root inputs).
- **COSMIC, added 2026-07-11 as a secondary session, not primary DE.**
  `services.desktopManager.cosmic` has been a first-class NixOS module since
  25.05 (well before this flake's 26.05 pin) — no third-party flake needed.
  Added via a new `modules/nixos/desktop-cosmic.nix`, deliberately *not*
  enabling `services.displayManager.cosmic-greeter` — SDDM (from
  `desktop-plasma.nix`) stays the sole display manager, and just gains a
  second selectable "COSMIC" session alongside Plasma, since NixOS
  desktop-manager modules install session files any active display manager
  picks up. *Why not primary:* as of COSMIC Epoch 1.2.0 (2026-06-30, ~2
  weeks old at time of writing) there's no `plasma-manager` equivalent yet
  — anything customized in COSMIC lives unmanaged in `~/.config/cosmic/`,
  not declared in this repo — and VRR/HDR still haven't landed, which
  matters concretely here since `gamescopeSession` in `gaming.nix` was
  specifically chosen for NVIDIA + VRR. Revisit primary-DE status once
  those land.
- **`programs.plasma.hotkeys.commands` (plasma-manager) is broken — don't use
  it, 2026-07-13.** Confirmed hands-on after an extremely long debugging saga
  (Vicinae's global toggle hotkey, bound via this module, appeared to fire —
  correct entry in `kglobalshortcutsrc`, "Started Plasma Manager" in the
  journal — but the actual window just flashed in the dock and closed a
  second later, no matter the key). Root cause: this module synthesizes a
  hidden multi-action desktop entry (one `.desktop` file, N actions), and
  KGlobalAccel doesn't correctly resolve the shortcut to the specific named
  action — it launches the entry's own (empty) main `Exec` instead. This
  matches the open upstream issue nix-community/plasma-manager#571 exactly
  ("app flashes briefly in the taskbar, keybind doesn't function").
  Confirmed via a clean A/B test: binding the identical command through
  System Settings' native "Add Custom Shortcut" flow (Plasma 6.1+) worked
  with zero glitching.
  **Fix/pattern going forward:** don't use `hotkeys.commands` at all. Use a
  plain, standalone, single-`Exec` desktop entry (`xdg.desktopEntries`) for
  the *launch target* — but do NOT rely on `X-KDE-Shortcuts` in that entry
  to bind the actual key. That was this session's first attempt and it's
  *also* unreliable: rebuilding ksycoca (needed for KGlobalAccel to
  discover the new entry at all) appears to make KDE treat previously-known
  services as newly-discovered and auto-apply their compiled-in default
  shortcuts — clobbering unrelated overrides already sitting in
  `kglobalshortcutsrc` (confirmed: this silently reset KRunner's shortcut
  back to its default) — while the new entry's own `X-KDE-Shortcuts`
  *didn't* reliably get auto-applied either.
  Next attempt: write `kglobalshortcutsrc` explicitly for every binding
  (`programs.plasma.shortcuts."services/<name>.desktop"._launch`), ordered
  *after* the `kbuildsycoca6` rebuild rather than before. This is the
  pattern used in `hosts/pegasus/home.nix` (daily-driver session) and it's
  fine there — but for Dragonized specifically, **it still wasn't enough**:
  KRunner's shortcut kept resetting regardless of ordering. Best working
  theory: because Dragonized wipes its whole profile on *every* login (not
  just once, ever), KDE's "is this a service I've seen before" bookkeeping
  never persists, so it looks like a first-ever login every single time —
  no ordering trick inside one script run can outrun that.
  **Final fix for Dragonized (`modules/nixos/desktop-dragonized.nix`):**
  stopped fighting it declaratively. `kglobalshortcutsrc` is now exempted
  from the wipe — backed up before `rm -rf`, restored after the session's
  setup completes. Configure shortcuts once through System Settings'
  native GUI (proven to work cleanly throughout this entire saga, every
  single time it was tried) and they persist across logins from then on,
  while everything else in the profile still gets the normal clean reset.
  This whole saga was also tangled up with an unrelated, genuinely separate
  bug (see MANUAL-STEPS.md §13/14) — Dragonized's isolated
  `XDG_CONFIG_HOME` meant the *first* few fix attempts were silently
  targeting the wrong session's config entirely, which delayed finding
  the real bugs considerably. If debugging a Dragonized-session
  shortcut/config issue again: verify against the actual running store
  path (`find /nix/store -maxdepth 1 -iname "*<name>*"` + compare hashes)
  before assuming a fix didn't work — and remember the isolated profile is
  wiped every login, which defeats any "first-run only" assumption KDE's
  own subsystems make.
- **Remote desktop → KRDP (KWin's built-in RDP server), bound to tailscale0
  only, added 2026-07-16.** *alt considered:* TigerVNC as a headless/virtual
  X11 session (rejected — pegasus's desktop is Wayland/KWin, so this would be
  a second, independent desktop rather than a view of the actual running
  session, and it's more moving parts for less payoff here); wayvnc (rejected
  outright — it needs wlroots' screencopy protocols, which KWin doesn't
  implement, so it can't work with Plasma at all). *Why KRDP:* it's Wayland-
  native (uses KWin's own screencast/remote-desktop portal, so it mirrors and
  controls whatever session is actually live, hardware-accelerated), and it
  already ships with `services.desktopManager.plasma6.enable` (it's in that
  module's `optionalPackages` upstream) — no new packaging.
  *Access-model choice:* bind to `tailscale0` only (already a
  `trustedInterfaces` member, same boundary z's SSH access already rides on)
  rather than binding to localhost and requiring a manual `ssh -L` tunnel per
  connection — chosen for day-to-day convenience over the more literal
  "SSH pubkey tunnel" reading of the ask. Caveat logged in
  `hosts/pegasus/MANUAL-STEPS.md` §14 and as an inline comment in
  `configuration.nix`: RDP's own login is PAM password/PIN, not a pubkey —
  KDE's Remote Desktop KCM has no NixOS module (no declarative
  enable/port/credentials), so the actual "pubkey-gated" property comes from
  Tailscale's device-key trust at the network layer, not the RDP handshake
  itself. Enabling it is therefore a one-time manual step in System Settings,
  and must be done in the daily-driver Plasma session specifically —
  Dragonized wipes its profile every login and would silently drop the
  setting.
- **iDrive — deferred, not packaged yet, 2026-07-13.** Not in nixpkgs.
  Investigated packaging `IDriveForLinux.deb` (v1.8.0, direct download from
  `idrivedownloads.com` — this session's environment can't fetch that URL
  itself, policy-blocked at the proxy; user downloaded and provided
  `sha256sum`/`dpkg-deb -I`/`dpkg-deb -c` output instead). Turns out to be a
  much bigger lift than the other Electron-app packages in this repo
  (Discord, Ferdium, etc.): its declared `Depends:` include
  `redis-server|valkey`, `cron`, `python3-nautilus`, `python3-pip`,
  `python3-watchdog`, `python3-psutil`, `gir1.2-nautilus-4.0`, `rsync`,
  `attr`, `xdotool` — a Redis-backed background daemon, cron-scheduled
  backups, and a Nautilus (file manager) right-click extension, all wired
  up by a 900-line `postinst` script doing real system-level setup
  (Nautilus extension registration, likely `pip install` of Python deps,
  cron configuration) at install time. A simple `home.nix` Electron-wrapper
  package (the pattern used for every other unfree Electron app here) would
  only get the GUI window running — scheduled backups, Nautilus
  integration, and the daemon itself would silently not work.
  **Decided:** worth doing properly as a real NixOS module (a redis/valkey
  service, Nautilus extension wiring, bundled Python deps via
  `python3.withPackages`, cron/systemd-timer handling) — closer in scope to
  `ollama.nix` than a package add — rather than a late-night rush job. Not
  started. Package name reference if picked up later: `idriveforlinux`,
  main binary `/opt/IDriveForLinux/idriveforlinux %U`, icon
  `idriveforlinux`, `StartupWMClass=IDriveForLinux`.
