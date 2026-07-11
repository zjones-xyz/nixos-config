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
