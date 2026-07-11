# pegasus — handoff

Pause point for the `pegasus-bringup` branch ([PR #6], OPEN). Read this first,
then the deeper docs alongside it.

## Where things stand

- **All authoring is done and committed** (6 per-phase commits, `[pegasus]`/
  `[serenity]` prefixed). Branch is pushed; PR #6 is open against `main`.
- **Validated by eval only.** `nix flake check --no-build --all-systems` is green
  and every closure instantiates to a `.drv` (pegasus, serenity, memory-alpha,
  hopper, hamilton). **Nothing has been built or activated on hardware** — this
  Mac (aarch64-darwin) has no Linux builder, so building pegasus is itself a
  manual step on the box.
- serenity (the Mac) has nix-darwin activated already (PR #7).
- **Install is in progress on real hardware (2026-07-11).** CachyOS's drive was
  pulled entirely rather than dual-booted — pegasus is now single-NVMe (see
  the "SUPERSEDED 2026-07-11" note in `DECISIONS.md` and updated
  `MANUAL-STEPS.md` §1 / `disko.nix`). First install attempt skipped
  `disko.nix` and used the installer's auto-partitioner instead, giving the
  wrong layout (no `@snapshots`/`@games`, a real LUKS swap partition instead
  of zram) — being redone with `disko.nix` properly.
- **SSH bootstrapping note**: the plain generated `/etc/nixos/configuration.nix`
  used for the first install attempt doesn't carry `modules/nixos/common.nix`'s
  `services.openssh` + authorized-key wiring — that only lands once the real
  `nixos-rebuild switch --flake .#pegasus` happens. Until then, SSH into the
  installed system needs `services.openssh.enable = true;` added to the local
  generated config by hand (see chat history, not written up as a doc step
  since it's a one-time bootstrap quirk, not a repeatable procedure).
- **Rebased onto `main` (2026-07-10)** to pick up ~40 commits of fleet drift
  (memory-alpha NUT/reboot fixes, jellyfin-pretranscode, the Arcane
  manager/agent module, shared starship/direnv/interactive-zsh unification,
  etc.). No textual conflicts — the PR only touches `hosts/pegasus/`,
  `flake.{nix,lock}`, `.sops.yaml`, `CLAUDE.md`, and net-new `modules/nixos/*`
  files, none of which main also changed. Re-validated green with
  `.claude/hooks/flake-check-sandboxed.sh --all-systems --impure`. Note: the
  `arcane-agent` module (`modules/nixos/arcane-agent.nix`) now exists on
  `main` but is still **not** wired into `hosts/pegasus/configuration.nix` —
  that wiring is still gated on real hardware existing to generate a manager
  token from, per `DECISIONS.md`'s original note, so it's out of scope here.

## Read these (don't re-derive)

- `DECISIONS.md` — every choice + deviation, incl. why this is one branch instead
  of the brief's five, and the gated-sops approach.
- `MANUAL-STEPS.md` — the install → first-switch → validation → activation
  checklist that is Zoe's to drive.
- `SECRETS-TODO.md` — `secrets/pegasus.yaml` provisioning.

## Top things to remember when you resume

1. **`hardware-configuration.nix` is a PLACEHOLDER** (fake UUIDs). Regenerate on
   real hardware (or drive the install with `disko.nix`) before any deploy.
2. **Olla won't build yet** — `modules/nixos/olla-router.nix` uses `lib.fakeHash`
   for `version`/`src.hash`/`vendorHash`. Fill them in (MANUAL-STEPS §5), and
   verify Olla's YAML config schema against its current docs (the schema here is
   illustrative) and the 1070 node hostname (placeholder `gpu1070.internal`).
3. **Confirm the Mac hostname `serenity`** (`scutil --get LocalHostName`) before
   activating the darwin config. nix-darwin is pinned to `nix-darwin-26.05`;
   `nix.enable = false` so it coexists with Determinate Nix.
4. **First switch should be Phase-1-only** (comment the gaming/perf/ollama/olla
   imports), from a TTY/other host — never over the display pegasus is
   reconfiguring. Re-enable the rest on a second switch.
5. **sops/tailscale wiring is inert** until `secrets/pegasus.yaml` exists (gated on
   `builtins.pathExists`), so eval stays green meanwhile. `.sops.yaml` already has
   a pegasus placeholder key + creation rule.

## Verify-before-trusting

These were validated at authoring time against the pinned nixpkgs but should be
re-checked if the lock moves: `services.ollama` uses `pkgs.ollama-cuda` (the old
`acceleration` option is gone); `services.scx.scheduler = "scx_lavd"`. Re-run
`nix flake check --no-build --all-systems --impure` after any `nix flake update`.

**`nix flake check` has a blind spot, confirmed 2026-07-11**: it did not catch
a missing `specialArgs = { inherit self; };` on `pegasus`'s `nixosSystem` call
(needed by `modules/nixos/motd.nix`, which landed on `main` after this branch
forked) — `nixos-install` failed on the real box with `attribute 'self'
missing` even though `flake check` reported green. `flake check` doesn't force
the same evaluation depth as an actual build. To catch this class of bug
before hardware, force it directly:
`nix eval --impure .#nixosConfigurations.<host>.config.system.build.toplevel.drvPath`
(with the same per-input `--override-input` overrides
`flake-check-sandboxed.sh` uses, if running from a web session).

## Not blocking pegasus (separate, pre-existing)

memory-alpha prod-cert flip (PR #5) and the other carried-over homelab tasks are
unrelated to this branch — don't conflate them with pegasus bring-up.

[PR #6]: https://github.com/zjones-xyz/nixos-config/pull/6
