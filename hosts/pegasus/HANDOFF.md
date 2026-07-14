# pegasus — handoff

Pause point for the `pegasus-bringup` branch ([PR #6], OPEN). Read this first,
then the deeper docs alongside it.

## Where things stand

- **pegasus is installed on real hardware and in daily use** (single NVMe,
  CachyOS drive removed). Base, gaming, performance, Ollama, and all three
  desktop sessions (Plasma, COSMIC, Dragonized) have been switched to and
  exercised — this is well past the original "first switch" milestone.
- serenity (the Mac) has nix-darwin activated already (PR #7).
- `hosts/pegasus/hardware-configuration.nix` is the real, reconciled config
  from the actual install (regenerated 2026-07-11 via `disko.nix`), not a
  placeholder.
- `secrets/pegasus.yaml` exists and is committed (sops-encrypted), and
  `.sops.yaml` carries pegasus's real age key — the sops/Tailscale wiring in
  `configuration.nix` is live, not inert.
- Rebased onto `main` (2026-07-10) with no textual conflicts — the PR only
  touches `hosts/pegasus/`, `flake.{nix,lock}`, `.sops.yaml`, `CLAUDE.md`, and
  net-new `modules/nixos/*` files.
- Validated throughout by `nix flake check --no-build --all-systems` plus a
  forced `.drv` eval (see "flake check has a blind spot" below for why the
  deeper eval matters).

## Read these (don't re-derive)

- `DECISIONS.md` — every choice + deviation, including the full Dragonized
  debugging saga and the plasma-manager `hotkeys.commands` bug writeup.
- `MANUAL-STEPS.md` — the live checklist; the section numbers referenced below
  point back into it for full detail.
- `SECRETS-TODO.md` — kept for reference; the `secrets/pegasus.yaml`
  provisioning it walks through is now done.

## Genuinely still open

1. **Olla router is disabled.** `modules/nixos/olla-router.nix`'s
   `version`/`src.hash`/`vendorHash` are real (resolved on-device), but its
   import is commented out in `configuration.nix` — Olla's own Go test suite
   fails under the Nix sandbox's constrained CPU scheduling
   (`TestEventBus_HighVolumePublishing`), not a real defect. Re-enabling needs
   `doCheck = false;` (or an upstream fix) plus the real 1070-node hostname
   (still the `gpu1070.internal` placeholder). See MANUAL-STEPS §5.
2. **Dragonized has a few open cosmetic gaps**: the Sweet cursor/color theme
   has no packageable source and falls back to something else, the Kickoff
   distributor-logo icon isn't packaged, SDDM's theme selector still points at
   its default rather than `Dr460nized`, and whether Kvantum is actually the
   active Qt style hasn't been visually confirmed. See MANUAL-STEPS §12.
3. **YubiKey enrollment is a manual, key-in-hand step** (`pamu2fcfg`) — not yet
   done. See MANUAL-STEPS §13.
4. **Gaming-window GPU drain and the overnight batch job are stubs** — the
   gamemode start/end hook needs confirming against real usage, and the batch
   script just logs a TODO. See MANUAL-STEPS §6.
5. **iDrive backup client is deferred entirely** (2026-07-13) — needs a real
   NixOS module (redis/valkey, Nautilus extension, cron/timer), not a simple
   package add. Not started.

## Verify-before-trusting

These were validated at authoring time against the pinned nixpkgs but should be
re-checked if the lock moves: `services.ollama` uses `pkgs.ollama-cuda` (the old
`acceleration` option is gone); `services.scx.scheduler = "scx_lavd"`. Re-run
`nix flake check --no-build --all-systems --impure` after any `nix flake update`.

**`nix flake check` has a blind spot, confirmed 2026-07-11**: it did not catch
a missing `specialArgs = { inherit self; };` on `pegasus`'s `nixosSystem` call
(needed by `modules/nixos/motd.nix`, which landed on `main` after this branch
forked) — `nixos-install` failed on the real box with `attribute 'self'
missing` even though `flake check` reported green. This is now fixed
(`flake.nix` passes `specialArgs = { inherit self; };`), but `flake check`
still doesn't force the same evaluation depth as an actual build in general.
To catch this class of bug before hardware, force it directly:
`nix eval --impure .#nixosConfigurations.<host>.config.system.build.toplevel.drvPath`
(with the same per-input `--override-input` overrides
`flake-check-sandboxed.sh` uses, if running from a web session).

## Not blocking pegasus (separate, pre-existing)

memory-alpha prod-cert flip (PR #5) and the other carried-over homelab tasks are
unrelated to this branch — don't conflate them with pegasus bring-up.

[PR #6]: https://github.com/zjones-xyz/nixos-config/pull/6
