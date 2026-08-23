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
   **Reversed 2026-08-01 (temporarily):** `services.scx.enable = false` — pegasus
   crashes when games launch under its actual workload. With no BPF scheduler
   attached the kernel falls back to its in-tree default, EEVDF. The scheduler
   choice is left recorded in `modules/nixos/performance.nix` so returning to scx
   is a one-word change; whether `scx_lavd` specifically is the culprit, or scx
   in general, is untested.
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
- **Niri, added 2026-08-10 as a fourth selectable SDDM session (bare, no
  shell layered on yet).** Same additive pattern as COSMIC — SDDM stays the
  sole display manager, `defaultSession` stays "plasma-dragonized", Niri just
  gains an entry in the session picker. Used nixpkgs' own `programs.niri`
  module (`nixos/modules/programs/wayland/niri.nix`, confirmed against the
  `release-26.05` branch, not niri-flake) — Niri is packaged directly in
  nixpkgs, no third-party flake input needed, unlike Dragonized's fetchGit
  sources or Claude Desktop's flake input. The module already registers its
  own session file (via `services.displayManager.sessionPackages`) and wires
  up the upstream-recommended portal config (xdg-desktop-portal-gnome +
  gnome-keyring + a Nautilus dbus-service backend for the FileChooser
  portal), so `modules/nixos/desktop-niri.nix` only needed two lines:
  `programs.niri.enable = true;` and `xwayland-satellite` in
  `environment.systemPackages` (Niri, unlike KWin/Mutter, has no built-in
  Xwayland — it auto-integrates xwayland-satellite once the binary is on
  PATH; needed for the X11-only apps already in daily use here — Discord,
  some Steam titles, Bambu Studio/OpenSCAD).
  *NVIDIA fit, confirmed on real hardware 2026-08-10:* explicit sync (fixes
  flicker/stutter on NVIDIA Wayland) needs driver >=555 and kernel >=6.8 —
  both already satisfied by this host's existing `nvidia.nix`/kernel choice,
  made for Plasma/COSMIC/Dragonized, so no changes needed there. Niri uses
  smithay, not wlroots, so none of the wlroots-specific NVIDIA env-var
  workarounds apply. First login confirmed clean rendering (1920x1080@60Hz,
  no EGL/DRM errors) and `xwayland-satellite` working (Discord spawned and
  tiled normally). The known cosmetic quirk flagged upstream — driver
  doesn't release VRAM properly under Niri, idles near ~1 GiB instead of
  ~100 MiB — was NOT hit in its severe form here (idle baseline measured at
  392 MiB); worth re-checking after extended real use. Full verification
  log in MANUAL-STEPS.md §15, including how the physical console's black
  screen from the switch below was diagnosed and fixed.
  *Deliberately deferred:* no shell (DankMaterialShell or Noctalia) layered
  on top yet — bare Niri first, to confirm the compositor+NVIDIA session is
  solid on real hardware before adding Quickshell's dependency footprint.
  Both candidate shells need extra flake inputs to reach on this repo's
  pinned `nixos-26.05` (Noctalia's nixpkgs package is unstable-only; DMS
  ships as its own flake, no nixpkgs package at all) — same shape as the
  `claude-desktop-debian` input already in this repo, deferred until a shell
  is actually chosen.
- **DankMaterialShell chosen over Noctalia, 2026-08-11, once bare Niri was
  confirmed solid on real hardware.** Both are Quickshell-based, both ~13
  months old at decision time. Checked actual community signal rather than
  guessing: GitHub activity (Noctalia: 9,423 stars/683 forks/222 open
  issues ≈2.4% of stars; DMS: 7,553 stars/471 forks/427 open issues ≈5.7%
  of stars — Noctalia has more traction and a lower issue ratio, though DMS
  has more surface area by design: bar, launcher, notification center,
  control center, lock screen, plugin system, Go backend, vs Noctalia's
  deliberately minimal "quiet by design" scope); a [HN
  thread](https://news.ycombinator.com/item?id=46841741) ("DMS... works
  better on NixOS out of the box... Noctalia [suits] slimmer builds");
  and a [hands-on comparison](https://www.logctl.com/posts/why-i-chose-niri-dms/)
  where the author ran Noctalia on a simple single-monitor laptop
  successfully but had it "not work out as smoothly as expected" on a
  complex multi-monitor desktop, where DMS "came together surprisingly
  smoothly" instead. Deciding factor: pegasus is going multi-monitor soon,
  which is Noctalia's one concretely documented weak spot in everything
  checked.
  *Implementation, `modules/nixos/desktop-niri.nix`:* added
  `dank-material-shell` as a flake input (`git+https://` for the same
  sandboxed-GitHub-access reason as `claude-desktop-debian`; unlike that
  precedent, DMS's transitive `github:` inputs — `dank-qml-common`,
  `flake-compat` — resolved fine from here, no follow-up lock needed on
  pegasus itself), `inputs.nixpkgs.follows = "nixpkgs"`. Used DMS's
  **`nixosModules.dank-material-shell`**, not its home-manager module — it
  matches how every other `desktop-*.nix` on this host is wired
  (Plasma/COSMIC/Dragonized are all NixOS-level), and it avoids needing a
  `programs.quickshell` home-manager option this repo doesn't otherwise
  pull in (the NixOS module just does `environment.systemPackages` +
  `systemd.user.services.dms` directly). Quickshell itself (the QML engine
  DMS runs on) is already in nixpkgs 26.05 at exactly 0.3.0 — DMS's own
  stated minimum — so no separate quickshell flake input was needed,
  confirmed by checking the actual `version` in nixpkgs'
  `pkgs/by-name/qu/quickshell/package.nix` on the `release-26.05` branch
  rather than assuming from an out-of-date `dms doctor` report (0.2.1) seen
  during research.
  *Deliberately skipped: DMS's `homeModules.niri` keybind-injection layer*
  (would bind `Mod+Space` → launcher, `Mod+N` → notifications, etc.). That
  module writes into `programs.niri.settings`, an option that only exists
  under **niri-flake**'s home-manager module — this host deliberately uses
  plain nixpkgs' `programs.niri` instead (see the earlier bare-Niri entry
  above), so adopting it would mean pulling in niri-flake just to get
  keybinds, a bigger architectural change than "add a shell." This repo
  already has a precedent for not fighting declarative keybind config for
  a shell layer — see the `programs.plasma.hotkeys.commands is broken`
  entry below, where Dragonized's shortcuts ended up configured live
  instead of declaratively. Same call here: DMS's keybinds get hand-added
  to `~/.config/niri/config.kdl` after first login — see MANUAL-STEPS.md
  §16 for the exact lines (sourced directly from DMS's own `niri.nix`
  module so they match what it would have generated).
  *Not verified — needs a real x86_64-linux build on pegasus:* the
  `dms-shell` package is a Go build with a pinned `vendorHash`; `nix flake
  check`/forced `drvPath` eval both pass clean from this Mac (no Linux
  builder here), but a vendorHash mismatch only surfaces at actual build
  time, same caveat as Olla's packaging in this repo.
- **Two general "additive session" gotchas found during Niri's first
  real-hardware test, 2026-08-10 — relevant to COSMIC and any future
  session too, not Niri-specific:**
  1. **`nixos-rebuild switch` can crash an already-logged-in graphical
     session on this host**, not just fail to affect it. A Dragonized
     session had been logged in since Aug 8 (two days) when the switch
     that added Niri ran; activation's user-unit reload
     ("restarting the following user units: nixos-activation.service...")
     crashed it outright (`sddm-helper... crashed exit code 1`), and no
     new greeter re-spawned afterward — full black screen on the physical
     KVM feed, `display-manager.service` itself never restarted so it
     looked "fine" from a pure systemd-status check. Fixed with
     `sudo systemctl restart display-manager` (no reboot needed — nothing
     salvageable was left running). *Takeaway: before switching, check
     `loginctl list-sessions` for an active graphical session, not just
     whether whoever's driving the switch is physically at the console* —
     asking "are you logged in locally right now" isn't sufficient, a
     stale session from days earlier is invisible unless you actually look.
  2. **Long-lived, D-Bus-activated user services don't pick up a new
     session's environment just because you switched sessions live.**
     `xdg-desktop-portal.service` had been running since that same Aug-8
     Dragonized login and never restarted when Niri started, so its own
     process environment (confirmed via `/proc/<pid>/environ`) was still
     `XDG_CURRENT_DESKTOP=KDE` even though `systemctl --user
     show-environment` correctly showed the session-wide value as `niri`
     — portal calls from Niri apps would have been routed against a
     desktop that was no longer active. Fixed with
     `systemctl --user restart xdg-desktop-portal.service`, confirmed via
     `busctl --user call ... Screenshot`. Same mechanism would affect any
     other long-lived `--user` service that reads `XDG_CURRENT_DESKTOP`
     once at startup — worth checking for on the next live session switch
     (COSMIC or otherwise), not just after a fresh reboot.
- **niri-flake adopted for declarative config, 2026-08-11 — but only its
  `homeModules.config`, not the full `nixosModules.niri`.** Motivation: the
  hand-edited `~/.config/niri/config.kdl` (natural-scroll disabled by hand,
  DMS's keybinds still not wired in) was unmanaged, unversioned state
  sitting only on pegasus's disk — real drift/loss risk if the disk is ever
  wiped or reinstalled. Checked what adopting niri-flake would actually
  cost before doing it (see `sodiboo/niri-flake`'s actual source, not just
  its reputation):
  - `nixosModules.niri` is a **hard replacement**, not an addition — it
    literally sets `disabledModules = [ "programs/wayland/niri.nix" ]`,
    turning off nixpkgs' module and installing niri-flake's own
    from-source build instead. Rejected: its "stable" track is pinned to
    `v25.08`, while nixpkgs 26.05's niri self-reports as version **26.04**
    — nixpkgs is currently *ahead*, so this would be a downgrade, not the
    usual "niri-flake tracks upstream faster" benefit. It would also mean
    either compiling niri from source or opting into a third-party binary
    cache (`niri.cachix.org`, run by the flake's maintainer) — a new trust
    boundary this repo hasn't taken on anywhere else — and it runs its own
    polkit agent alongside whatever Plasma already runs, untested here.
  - `homeModules.config` (used instead) is genuinely additive per its own
    README: "won't install niri by itself, but it does set the package
    version used for build-time validation." It only adds
    `programs.niri.settings` (declarative, KDL-validated at build time)
    and `config.lib.niri.actions`. `programs.niri.enable` from nixpkgs
    (above in `desktop-niri.nix`) is completely unchanged — set
    `programs.niri.package = pkgs.niri;` so niri-flake validates against
    the niri actually installed, not its own build.
  - ⚠ **Divergence risk, explicitly asked to be tracked**: niri-flake's own
    README states `programs.niri.settings`'s schema "is not guaranteed to
    be compatible with niri versions other than the two [niri-flake]
    provides," and that nixpkgs' niri is fine "unless running old versions
    2+ releases behind." True today (nixpkgs is ahead, not behind), but if
    that flips — nixpkgs lags, or niri-flake's schema changes out from
    under an unbumped input — expect either an eval error naming an
    unknown niri action, or worse, a config that builds but silently
    doesn't do what's declared. See the divergence-risk comment at the top
    of `hosts/pegasus/niri-settings.nix` for the full note kept next to
    the actual settings.
  - Concretely hit and fixed migrating the hand-tuned binds: **4 of the
    ~90 action names used aren't in niri-flake's `config.lib.niri.actions`
    cache** (`screenshot`, `screenshot-screen`, `screenshot-window`,
    `move-column-to-workspace` — all take optional properties or a
    non-trivial argument type the cache's generator apparently skips),
    caught as Nix eval errors (`undefined variable`) and fixed by using
    the documented `action.<name> = value` attrset form for just those
    four instead of the `with config.lib.niri.actions;` bare-name form
    used everywhere else. Also: `hotkey-overlay.title` doesn't accept
    `null` for hiding a bind from the overlay — that's
    `hotkey-overlay.hidden = true;` instead. All caught by `nix flake
    check`/forced eval before ever reaching pegasus — see
    `hosts/pegasus/niri-settings.nix`.
  - **Not using DMS's own `homeModules.niri`** (which would auto-generate
    DMS's keybinds) — that module needs DMS's `homeModules.dank-material-
    shell` also imported at the home-manager level for its `cfg.enable`
    reference to resolve, which reintroduces the exact `programs.
    quickshell` HM-option exposure avoided by using DMS's NixOS module
    (see the earlier DMS entry above). DMS's ~8 keybinds are hand-
    transcribed into `niri-settings.nix` instead, matching upstream's own
    bind list. Doing this surfaced **3 real key conflicts** between niri's
    own suggested defaults and what DMS wanted the same key for:
    `Mod+Comma` (niri: consume-window-into-column; DMS: settings panel —
    niri's moved to `Mod+Shift+Comma`), `Mod+V` (niri: toggle-window-
    floating; DMS: clipboard manager — niri's moved to `Mod+Ctrl+V`,
    paired with the existing `Mod+Shift+V`), and the six volume/brightness
    media keys (niri's raw `wpctl`/`brightnessctl` calls replaced with
    DMS's own `dms ipc audio/brightness ...` so DMS's on-screen indicators
    actually fire — media *transport* keys like play/pause have no DMS
    equivalent and were left as niri's original `playerctl` bindings).
  - **Not verified on real hardware.** `nix flake check` and a forced
    `system.build.toplevel.drvPath` eval both pass clean, but niri-flake's
    own build-time KDL validation (`validated-config-for`, which actually
    runs niri's validator against the generated config) only executes
    during a real derivation *build*, which this Mac can't do for
    x86_64-linux. The Nix-level checks catch wrong option names/types
    (as they did, four times, above) but not e.g. a syntactically-valid-
    to-Nix KDL value that niri itself would still reject. First real
    `nixos-rebuild switch` on pegasus is the actual test.
  - Also: the pre-existing hand-edited `~/.config/niri/config.kdl` isn't
    home-manager-owned, so it collides with home-manager now declaring
    that same path — added `home-manager.backupFileExtension =
    "pre-declarative-niri-config";` for pegasus (matching the pattern
    already used for serenity's pre-existing dotfiles) so activation
    renames rather than aborts on it. The old file will sit there
    afterward as `config.kdl.pre-declarative-niri-config` — home-manager
    doesn't clean these up on its own.
  - **First real `nixos-rebuild switch` attempt, 2026-08-11: niri-flake's
    KDL build-time validation passed clean** — `config.kdl.drv` built with
    no error, meaning every one of the ~90 transcribed binds (plus the
    touchpad settings and window-rule) validated against real niri. The
    switch still failed, but on something unrelated to niri or this
    file: DMS's Go build (`dms-shell`) needs Go ≥1.26.4, and this repo's
    then-pinned `nixpkgs` (2026-06-11) only had 1.26.3. Not a DMS commit
    problem — checked, `go.mod` had required 1.26.4 for a while already —
    just a stale lock; the `nixos-26.05` branch tip already had 1.26.5.
    **Fixed by bumping `nixpkgs` forward within the same `nixos-26.05`
    branch** (2026-06-11 → 2026-08-09; cascades to every `.follows`-linked
    input: home-manager, sops-nix, nix-darwin, plasma-manager,
    claude-desktop-debian, dank-material-shell, niri-flake). `nix flake
    check` re-run clean across all five hosts after the bump before
    retrying on pegasus.
  - **Second switch attempt, same day, succeeded** — `Done.`, new
    generation activated. Notably `niri.service` was NOT restarted as
    part of activation (this switch didn't touch niri's own package),
    which is exactly why the already-logged-in Niri session on the
    physical console survived intact this time — contrast with the
    Niri-install switch in the entry above, which crashed the
    then-running Dragonized session.
  - **But two things still needed manual intervention post-switch, both
    now confirmed fixed and worth remembering for next time:**
    1. **Niri didn't live-reload the new config** — home-manager
       activation swaps `~/.config/niri/config.kdl`'s *symlink target*
       atomically (unlink + new symlink), not an in-place file edit.
       Niri's config file-watcher apparently doesn't pick this up the
       same way it does an in-place edit (confirmed: zero niri journal
       activity after the switch, versus a clear `loaded config from
       ...` log line during earlier hand-edit testing). Fixed with
       `systemctl --user restart niri.service` — this DOES restart the
       compositor (closes windows, black screen briefly), so only do
       this when nothing valuable is open, or expect users logged in
       physically to lose their session. After restart, journal showed
       `loaded config from "/home/z/.config/niri/config.kdl"` with no
       errors, confirming the full ~90-bind config validated at runtime
       too, not just at build time.
    2. **`dms.service` never auto-started, even after the niri restart
       above** — root cause is different from #1: `dms.service` is
       `WantedBy=graphical-session.target`, but that target had been
       continuously active since the *original* Niri login (Aug 10) and
       never itself stopped/restarted — restarting a sibling unit
       (`niri.service`) doesn't restart the target it belongs to, so a
       brand-new unit `WantedBy` an already-active target never gets an
       automatic start trigger. This is a generic systemd gotcha for any
       unit newly introduced by a switch into an already-running
       session's target graph, not niri- or DMS-specific. Fixed with a
       direct `systemctl --user start dms.service` — came up clean,
       quickshell + the Go backend both initialized without error
       (bluetooth/network/clipboard managers all fine). One harmless
       warning: `Failed to watch config directory: no such file or
       directory` — `~/.config/DankMaterialShell/` doesn't exist since
       `programs.dank-material-shell.settings` was never set; DMS just
       runs on its own defaults until/unless that's configured.
    **Takeaway for any future switch that adds a new `WantedBy=graphical-
    session.target` unit to an already-logged-in session: don't assume
    it auto-starts. Check `systemctl --user status <unit>` after
    switching, and `systemctl --user start` it directly if it's sitting
    `inactive (dead)`.**
- **Remote desktop → xrdp + xorgxrdp (Plasma-over-X11, independent session
  per connection), tailscale0-gated, added 2026-07-16/17.** *Real motivation
  surfaced mid-implementation:* this is meant to eventually replace the
  physical IP-KVM (until pegasus is wired into a desk KVM switch), which
  changes the requirement from "view my live desktop remotely" to "get a
  working desktop after any reboot/logout, with no dependency on the
  physical console's state."
  *First attempt: KRDP* (KWin's built-in RDP server, ships with
  `services.desktopManager.plasma6.enable`, no packaging needed) — chosen
  initially for being Wayland-native and mirroring the actual live session.
  **Ruled out once the real requirement surfaced**: KRDP only shares an
  *already-logged-in* KWin session — confirmed via KDE's own discussion
  forum that it has no headless mode and no plans for one. It also has
  real hardware-encode fragility on virtual/headless outputs (reaches for
  VAAPI first; sessions can collapse outright if no VAAPI encoder is
  present). A follow-up idea — SSH-triggering a headless `kwin_wayland
  --virtual` instance as a systemd `--user` service for krdpserver to
  attach to — was researched and dropped for the same reason: fighting an
  explicitly-unsupported upstream path, plus added NVIDIA-proprietary +
  virtual-output risk on top.
  *Why xrdp instead:* mature, fully declarative NixOS module
  (`services.xrdp`), and this nixpkgs's `xrdp` package already strips every
  sesman backend except `[Xorg]` (uses the bundled `xorgxrdp` driver) — so
  `defaultWindowManager = "startplasma-x11"` is the entire config. Each RDP
  connection gets its own independent Xorg/Plasma session, decoupled from
  SDDM and the physical seat entirely — reachable identically whether the
  console is at the greeter, locked, or logged out, with **no autologin
  needed** (autologin was considered and explicitly declined — see below).
  Trade-off accepted: it's Plasma over X11, a second session, not a mirror
  of the physical Wayland one.
  *Access-model:* `tailscale0` only, via the existing `trustedInterfaces`
  (not `xrdp.openFirewall`) — same boundary SSH already rides on. The
  `services.xrdp` module has no per-interface bind option, so (as with the
  superseded KRDP attempt) this is enforced at the firewall, not the
  listen socket.
  *Auth:* PAM against z's real account password (`z/hashedPassword`,
  already sops-provisioned for console/SDDM login) — no new credential to
  provision, and RDP still has no notion of pubkey auth, so as with KRDP
  the "pubkey-gated" property is Tailscale's device-key trust at the
  network layer, not the RDP handshake.
  *Autologin — considered and declined 2026-07-17*: SDDM autologin into the
  daily-driver session would have closed KRDP's post-reboot blind window,
  but was rejected — leaves the physical console password-free at boot,
  which was an unwanted trade purely to work around a KRDP limitation.
  Moot now that xrdp doesn't share the SDDM-managed session at all.
  *Genuinely out of scope for any software remote desktop* (KRDP or xrdp):
  BIOS/UEFI screens, the boot-loader menu, kernel panics/hangs — none of
  that has a Linux graphics stack yet for RDP to attach to. That gap is
  what the eventual physical desk KVM switch is for, not this. LUKS unlock
  is the one boot-time gap already closed, separately, via
  `boot.initrd.network.ssh` (pre-existing).
  **Not yet verified on real hardware** — xorgxrdp's driver is
  self-contained (doesn't touch the nvidia DDX) so is expected to coexist
  fine with the proprietary driver, but this needs an actual RDP connection
  test on pegasus to confirm. See `hosts/pegasus/MANUAL-STEPS.md` §14.
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
- **dankcalendar added 2026-08-11, chosen over sticking with khal+vdirsyncer
  alone.** Standalone calendar app (Local/Google/Microsoft/CalDAV/iCloud)
  from the same "Dank" suite as DMS — not a khal replacement, a genuinely
  separate app with its own daemon, tray icon, and native OAuth. Compared
  against khal directly before deciding: khal is already the lower-effort
  path (in nixpkgs, already wired as the backend for DMS's own calendar
  widget via `enableCalendarEvents`), but was still inert on this host —
  nothing had configured `vdirsyncer` to actually sync a real calendar into
  it. dankcalendar's native OAuth (no manual CalDAV URL/auth wrangling) and
  broader account support (iCloud, which khal+vdirsyncer doesn't cover as
  cleanly) won out, accepting that it runs *alongside* khal rather than
  replacing it — DMS's own widget still reads from khal, dankcalendar is a
  separate surface.
  *Packaging, `modules/nixos/dankcalendar.nix`:* no upstream Nix packaging
  exists (Flatpak/AUR/source-only at time of writing) — packaged from
  scratch, `buildGoModule` + the quickshell UI tree baked in via
  `go:embed`, following the exact shape of DMS's own package build.
  Pinned to master HEAD (`a57a8790`, no tagged release exists yet).
  Genuinely nontrivial part: replicating `core/Makefile`'s `sync-shell`
  target (copies `quickshell/` into `internal/shellembed/dist`, the
  `go:embed` target for the `withshell` build tag) — including resolving
  the `DankCommon` submodule symlink to `dank-qml-common`'s real content,
  since `go:embed` rejects symlinks (same reason the Makefile dereferences
  it via `tar -h`). Wrapped with the same Qt/QML plugin paths DMS's own
  package uses (`kirigami`, `sonnet`, `qtmultimedia`, `qtimageformats`,
  `kimageformats`) since both apps share the `dank-qml-common` widget
  library, plus an explicit `quickshell` on `PATH` rather than relying on
  it already being there system-wide via DMS's module.
  *All three hashes (dankcalendar source, dank-qml-common source, Go
  `vendorHash`) were resolved locally on this Mac* rather than round-
  tripping to pegasus for each — fetching and Go module vendoring are both
  architecture-independent operations (no actual compilation happens),
  confirmed by forcing each fixed-output derivation to build against
  `aarch64-darwin`'s own nixpkgs with `lib.fakeHash` and reading the real
  hash out of the resulting mismatch error. Only the final compile (`go
  build -tags withshell`) genuinely needed x86_64-linux.
  **First real build, 2026-08-11: succeeded on the first attempt** — no
  vendorHash mismatch, no embed-step failure, no compile error. Confirmed
  working end-to-end: `dcal version` reports the correct ldflags-injected
  version string, `dcal.service` starts clean and correctly spawns
  `quickshell` as a subprocess against the runtime-unpacked embedded UI
  (`/run/user/1000/dankcal-shell/...`), IPC socket comes up. One benign
  warning in the log (`Failed to register with host portal... Connection
  already associated with an application ID`) — same class of harmless
  D-Bus name-registration warning already seen from niri's own screensaver/
  keyboard-monitor services; service stayed active, not a crash.
  Same `graphical-session.target`-already-active gotcha as `dms.service`
  applied here too (see the niri-flake switch entry above) — needed a
  direct `systemctl --user start dcal.service`, didn't auto-start on its
  own.
  **Not yet done:** actually adding a calendar account (`dcal account`) —
  needs an interactive login (Google/Microsoft OAuth, or a CalDAV/iCloud
  app-password flow), can't be driven from this SSH session. See
  MANUAL-STEPS.md §18.

- **Keyring (Secret Service) → gnome-keyring, declared; KWallet's PAM unlock
  turned off.** *alt:* KWallet as the single provider, or leave both as-is.
  *Why:* nothing in the config named a keyring, yet three modules each pulled
  one in — `desktop-plasma.nix` (Plasma 6's kwalletd6 + ksecretd, with
  `pam_kwallet` wired into the `login` stack by nixpkgs' plasma6 module, which
  SDDM substacks), `desktop-cosmic.nix` and `desktop-niri.nix` (both
  `services.gnome.gnome-keyring.enable = lib.mkDefault true`, the latter also
  pinning `xdg.portal.config.niri."org.freedesktop.impl.portal.Secret"` to
  gnome-keyring). Evaluating the pre-change closure confirmed **both** were
  enabled and both auto-unlocked at every graphical login. Only one can own
  `org.freedesktop.secrets`, so which store the browsers and every Electron
  app actually wrote to was decided by startup order.
  That is sharper on this host than it sounds, because the `systemd --user`
  manager and `graphical-session.target` persist across session switches (the
  same property behind the `dms.service`/`dcal.service` auto-start gotcha
  above): the winner holds the bus name until a full logout or reboot, so
  secrets stored under one owner silently vanish under the other — presenting
  as "the browser forgot my logins", not as a keyring fault.
  gnome-keyring was picked because Niri is the daily-driver session and both
  it and COSMIC already default to it, niri's Secret portal is already pinned
  to it, and it is the only one of the two that needs no per-session glue in
  all four sessions. KWallet outside Plasma would need two pieces Plasma
  supplies for free: `ksecretd` started by hand (its D-Bus activation name is
  `org.kde.secretservicecompat`, never the `org.freedesktop.secrets` that apps
  request) and `plasma-kwallet-pam.service` given a `WantedBy` (it ships with
  `PartOf=graphical-session.target` and nothing else).
  Cost accepted: a KDE app in the Plasma/Dragonized sessions that genuinely
  wants the wallet now prompts rather than opening silently. Nothing on this
  host does — wired ethernet, no KDE PIM. Reversing the decision is the two
  `mkForce` lines in `modules/nixos/keyring.nix` plus disabling gnome-keyring.
  **Not verified on hardware** — the switch, and which daemon ends up owning
  the bus name afterward, still needs a real login. See MANUAL-STEPS.md §19.

- **DMS settings.json → snapshot/restore script, not a Home-Manager symlink**
  (2026-08-21). *alt:* `config.lib.file.mkOutOfStoreSymlink` pointing
  `~/.config/DankMaterialShell/settings.json` at a repo-tracked file, for
  live GUI edits to land directly in the git working tree. *Why rejected:*
  DMS persists settings via Quickshell's `FileView { atomicWrites: true }`
  (`Common/SettingsData.qml`), which writes a temp file and `rename()`s it
  over the target path. `rename()` onto a symlinked path replaces the
  symlink itself rather than following it to the target — so the first
  setting toggled through the DMS GUI would silently detach
  `settings.json` from the repo and turn it back into an ordinary file, with
  no error surfaced. `home.file`'s in-store form has the same problem plus
  it's read-only to begin with (DMS does detect that case — `onSaveFailed`
  sets an internal read-only flag — but that only means it fails safe, not
  that edits reach git).
  Went with `scripts/dms-settings.sh snapshot|restore` instead: `snapshot`
  copies the live file to `hosts/pegasus/dms-settings.json` for manual
  review/commit, `restore` copies it back (refuses to clobber an existing
  live file unless `FORCE=1`). `home.nix`'s `seedDmsSettings` activation
  script additionally seeds a *fresh* host (no live file yet) from that
  checkpoint, so a rebuild-from-scratch starts from the last-known-good
  config rather than DMS's defaults — it never touches an already-existing
  live file, so it can't clobber an in-progress GUI experiment.
  Checked the settings schema for anything that shouldn't be committed in
  plaintext: nothing secret (one unrelated `lockScreenShowPasswordField`
  bool); it does capture `weatherLocation`/`weatherCoordinates` if those get
  set, worth knowing before committing.
  **No checkpoint committed yet** — `hosts/pegasus/dms-settings.json` only
  exists after `dms-settings-snapshot` is run on real hardware with a DMS
  config worth keeping; nothing here fabricates one.
  **Extended 2026-08-23** to also cover `plugin_settings.json` (per-plugin
  enabled flag + config — a second file DMS saves the same atomic way,
  separate from `settings.json`), and added a `diff` action (compares live
  vs. checkpoint without touching either — what `snapshot` would capture or
  `restore` would overwrite). `snapshot`/`restore`/`diff` all now take an
  optional `[settings|plugins|all]` target, defaulting to `all`; `home.nix`'s
  `seedDmsSettings` seeds both checkpoints independently, same never-clobber
  rule as before.

- **Bambu Studio blank build plate (Prepare/Preview tabs), 2026-08-22 — fixed
  via `overrideAttrs` in `hosts/pegasus/home.nix`, routing its OpenGL canvas
  through Mesa + Zink instead of the NVIDIA vendor GL libs.** *alt 1:* bump
  this flake's shared `nixpkgs` input to a post-2026-05-27 `release-26.05`
  revision and use the real `withNvidiaGLWorkaround` package arg upstream
  shipped for exactly this. *Why not:* `nixpkgs` is a single input shared by
  every host in the fleet (`hosts/*`), so that bump would move package
  versions fleet-wide just to fix one desktop app on one host — too broad a
  blast radius for this. *alt 2:* switch to the Flatpak build (several
  reports it renders fine on identical NixOS/NVIDIA hardware) or to
  OrcaSlicer. *Why not:* this repo has no Flatpak plumbing, and OrcaSlicer is
  a separate app already installed alongside Bambu Studio, not a substitute
  for Bambu-specific cloud features.
  *Why the bug happens:* not niri/xwayland-satellite-specific — Bambu
  Studio's wxWidgets OpenGL canvas is broadly fragile against NVIDIA's
  proprietary GL on Linux; the toolbars/panels are plain widgets and render
  fine, only the GL-backed 3D canvas doesn't. Same symptom reported across
  Hyprland, GNOME, KDE X11, and Docker+NVIDIA — tracked upstream at
  https://github.com/NixOS/nixpkgs/issues/498311. nixpkgs fixed it via a
  `withNvidiaGLWorkaround` package arg
  (https://github.com/NixOS/nixpkgs/pull/522161, merged + backported to
  `release-26.05` 2026-05-27) that sets four env vars forcing the GL context
  through Mesa's Zink driver (OpenGL-over-Vulkan, still hardware-accelerated
  via NVIDIA's own Vulkan ICD) instead of NVIDIA's GLX/EGL vendor libs. This
  flake's `nixpkgs` was locked 2026-01-08, well before that merge, so the
  fix is hand-applied via `overrideAttrs` appending the same
  `gappsWrapperArgs` the upstream fix uses, rather than waiting for the pin
  to catch up.
  **Confirmed on hardware, same day:** the build plate renders correctly
  after `nixos-rebuild switch` on pegasus.

  **Superseded same day** by pulling `bambu-studio` from a second, standalone
  `nixpkgs-bambu-studio` flake input pinned to commit `13b979d` (2026-05-27,
  `git+https://github.com/NixOS/nixpkgs.git?rev=13b979d75662827615c1de6dd22f87e6296ba71d`)
  instead of the hand-rolled `overrideAttrs`. That commit both bumps
  `bambu-studio` to 02.05.00.67 (from this flake's pinned 02.03.01.51 — two
  version bumps: 02.04.00.70, then 02.05.00.67) *and* already carries the
  real `withNvidiaGLWorkaround` package arg, so `hosts/pegasus/home.nix` now
  just does `pkgs'.bambu-studio.override { withNvidiaGLWorkaround = true; }`
  against that pinned `pkgs'` — the actual upstream fix, not a hand-copied
  reimplementation of it — while keeping the same "don't touch the shared
  `nixpkgs` input" reasoning above (same blast-radius argument, this is a
  second isolated input, not a bump of the fleet-wide one).
  One gotcha hit doing this: `nixpkgs-bambu-studio.legacyPackages.<system>`
  (unlike the main `nixpkgs`, which gets `nixpkgs.config.allowUnfree = true`
  fleet-wide via `modules/nixos/common.nix`) has `allowUnfree` unset, and
  `bambu-studio` was marked `agpl3Plus unfree` in nixpkgs the same day as the
  GL fix (commit `4acf48b`) — evaluating it through plain `legacyPackages`
  throws. Fixed by constructing the pkgs set explicitly in `flake.nix`
  (`import nixpkgs-bambu-studio { system = ...; config.allowUnfree = true; }`)
  instead of using `legacyPackages` directly.
  Validated with `.claude/hooks/flake-check-sandboxed.sh` (`nix flake check`
  against every input rewritten to git+https at its exact locked rev, to
  route around this sandboxed session's GitHub-tarball-fetch 403 — see that
  script's own header comment) — exits 0 across all five configs. Actual
  `nixos-rebuild switch` + relaunch on pegasus still needed to confirm this
  refactor didn't change runtime behavior versus the already-confirmed
  hand-rolled version.

- **OrcaSlicer bumped 2.3.1 -> 2.3.2, 2026-08-22** — pulled from a third
  standalone flake input, `nixpkgs-orca-slicer`, pinned to nixpkgs commit
  `e749b91` (2026-03-23, the exact commit that bumped `orca-slicer` in
  nixpkgs), for the same reason and via the same mechanism as
  `nixpkgs-bambu-studio` above. *alt considered:* hand-override
  `version`/`src`/hash to chase OrcaSlicer's actual upstream latest stable
  (v2.4.2, 2026-07-07) directly, skipping nixpkgs entirely. *Why not, for
  now:* nixpkgs hasn't packaged anything past 2.3.2 yet (checked
  `release-26.05` HEAD 2026-08-22), so there's no already-vetted patch set
  for 2.4.x to build against — this repo's existing patches (webkit linking,
  opencv, cmake4, gcc15 stdint) are pinned to what 2.3.x needs, and
  reworking them by hand with no build/eval access in this session to
  validate against was judged not worth the risk for a UI that (confirmed on
  hardware, same day) already renders correctly at 2.3.1 — unlike Bambu
  Studio, this one isn't fixing a real bug, just chasing a newer version.
  No GL workaround applied here: OrcaSlicer's own NVIDIA/Zink route has a
  documented regression risk the Bambu Studio one doesn't (Zink reportedly
  breaks OrcaSlicer's Home/Device/Project pages and printer/filament preset
  dialogs on some driver versions — see
  https://github.com/OrcaSlicer/OrcaSlicer/issues/9474, closed
  not-planned/stale) — moot here since this host's viewport already works
  without it.
  Validated the same way as `nixpkgs-bambu-studio` above
  (`flake-check-sandboxed.sh`, exit 0). Not yet confirmed with a real
  `nixos-rebuild switch` on pegasus.

- **Opened UDP 2021 + 1900 on the firewall for Bambu printer LAN
  auto-discovery, 2026-08-22.** Bambu/Orca don't send a discovery query —
  the printer periodically broadcasts its presence over UDP (source port
  1900), and the slicer just listens for it on 2021. `networking.firewall.
  enable = true` is set fleet-wide (`modules/nixos/common.nix`), and until
  now nothing on pegasus opened either port, so that unsolicited inbound
  broadcast was silently dropped — the printer likely wasn't appearing on
  its own in LAN-only mode. *alt considered:* skip the firewall change
  entirely and add the printer manually by IP + access code in Bambu
  Studio (Device tab), since every actual data-plane connection — file
  send over FTPS, MQTT status, camera stream — is outbound from the
  slicer and was already unaffected by the firewall. *Why not:* Zoe wants
  real auto-discovery, not just a workaround.
  Requires the printer to be on the same L2 broadcast domain as pegasus —
  confirmed same VLAN, bridged across a LAN/WLAN boundary (i.e. wired
  pegasus, printer on Wi-Fi, same AP/VLAN) rather than crossing an actual
  router/VLAN boundary, which broadcast wouldn't survive without a relay
  (e.g. https://github.com/inindev/bambu-bridge). If discovery still
  doesn't work after this, suspect client isolation on the AP (common on
  guest/IoT SSIDs, blocks broadcast between wireless clients even on the
  same subnet) before assuming the firewall rule is wrong.
  Validated with `flake-check-sandboxed.sh` (exit 0). Not yet confirmed on
  hardware — needs `nixos-rebuild switch` + checking whether the printer
  now appears automatically in Bambu Studio's device list.
