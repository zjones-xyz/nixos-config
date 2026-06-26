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
- pegasus is still running CachyOS; serenity (the Mac) has no nix-darwin
  activation yet.

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

## Not blocking pegasus (separate, pre-existing)

memory-alpha prod-cert flip (PR #5) and the other carried-over homelab tasks are
unrelated to this branch — don't conflate them with pegasus bring-up.

[PR #6]: https://github.com/zjones-xyz/nixos-config/pull/6
