# The app lane (`nixpkgs-apps`)

The fleet runs on nixos-26.05. Apps that have to move faster than the
release, or that the release doesn't carry at all, come from a second nixpkgs
on nixos-unstable. This page holds the fleet-wide policy. The history of what
moved and why stays in `hosts/pegasus/DECISIONS.md`, where the lane started.

## Policy

- **Apps only.** Desktop or terminal apps are built against the lane, usually
  as `pkgsApps.<name>` (see Wiring for the other routes). The kernel,
  services and everything else stay on `nixpkgs`.
- **Never import modules from it.** Two nixpkgs' module sets collide on
  option definitions. For a newer service binary, set
  `services.<x>.package` instead.
- **One input, not a pin per app.** `nix flake update nixpkgs-apps` moves
  every app on the lane together. An app that has to hold back gets its own
  pin again, as the exception.
- **Leave once the release catches up.** When a stable release ships the
  app at a good enough version, move it back to plain `pkgs.<name>`.

## Wiring

There are two ways in.

**Home Manager (the usual one).** `flake.nix` defines `appsForHm system`. It
instantiates `nixpkgs-apps` for that system, with its own `allowUnfree`,
since a separate instance does not inherit `modules/nixos/common.nix`'s. It
passes the result to Home Manager as `pkgsApps`. Every host config includes
it except the live ISO, which has no Home Manager. `modules/home/common.nix`
takes `pkgsApps` as an argument, so a new host or standalone Home Manager
config that imports it needs `appsForHm` too, or evaluation fails with a
missing argument.

**System level (pegasus only).** `modules/nixos/hushmic.nix` reads
`self.inputs.nixpkgs-apps.legacyPackages` directly, and the `hushmic-nix`
input follows `nixpkgs-apps`. So a bump also rebuilds a NixOS-level package
on pegasus, not only its Home Manager profile. This is the one exception to
the policy above. HushMic is still an app, but its package reaches the host
outside Home Manager, as a system package, and runs as a systemd user
service defined in this repo. It takes no modules from the lane.

## Who uses it

| Scope | Apps | Since |
|---|---|---|
| Every host (`modules/home/common.nix`) | herdr | 2026-10-23, #218 |
| pegasus (`hosts/pegasus/home.nix`) | slicers, browsers, chat apps, ticktick | 2026-10-11/16 |
| pegasus (`hosts/pegasus/home.nix`) | coding agents: codex, copilot, opencode, pi, qwen | 2026-10-24 |
| pegasus (`kimi-cli`, `hermes-agent` flakes, following the lane) | Kimi Code, Hermes Agent | 2026-10-24 |
| pegasus (`modules/nixos/hushmic.nix`) | HushMic | 2026-10-14 |

On pegasus, "slicers" includes open-bamboo-networking (OrcaSlicer's network
plugin, `pkgsApps.callPackage`) and "chat apps" includes zoom-us. The
pegasus entries in its `DECISIONS.md` ("Desktop apps from `nixpkgs-apps`",
"Exposed apps on the fast lane", "HushMic as the noise-suppressed mic") list
the exact set and the overrides each one carries.

## Bumps

`.github/workflows/update-apps.yml` bumps `nixpkgs-apps` and the other
app-only inputs twice a week and opens an `[all] Bump app inputs` PR.
Merging and switching stay manual.

Because herdr is on every host, each bump changes every host's Home Manager
profile, servers and Pis included:

- **Switch the whole fleet after merging.** A host you skip keeps the old
  herdr. The Pis build through memory-alpha, per their `DEPLOY.md`.
- **A break on unstable stalls the whole lane.** The workflow evaluates every
  host before it opens a PR and stops at the first failure. An app in
  `modules/home/common.nix` (today, herdr) that fails to evaluate fails
  every host; a pegasus-only app fails just pegasus. Either way no bump PR
  opens until it's fixed. A failed scheduled run is the signal: hold that
  app back with its own pin, or wait for unstable to fix it.
- **Closure cost.** Lane packages link unstable's glibc and other libraries,
  so the first one on a host adds those beside the release's. For herdr on
  aarch64 that is about 87 MiB, which lands even on the Pis' SD cards.
- **Local compiles on pegasus.** Some lane apps there carry overrides or are
  unfree, so they build locally whenever a bump moves them (OrcaSlicer, Bambu
  Studio, open-bamboo-networking, HushMic). Budget that time at switch; the
  list is in pegasus's `DECISIONS.md`, "Exposed apps on the fast lane".
