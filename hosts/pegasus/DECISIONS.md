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
   from source in `modules/nixos/olla-router.nix`. **Olla is not in nixpkgs**, so
   the package uses PLACEHOLDER hashes (`lib.fakeHash`) — it evaluates but must
   have real `version`/`src.hash`/`vendorHash` filled in before it will *build*
   (see MANUAL-STEPS). Olla's YAML config schema here is illustrative — verify
   against current Olla docs.
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
