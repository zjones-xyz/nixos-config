# ─────────────────────────────────────────────────────────────────────────────
# Colmena hive — the deployment layer on top of flake.nix's `nixosConfigurations`.
# ─────────────────────────────────────────────────────────────────────────────
# `nix flake check` / `nix build .#nixosConfigurations.<host>...` still go
# through flake.nix exactly as before — this file only adds *how to ship* a
# closure to each host over SSH (`colmena apply`), replacing the per-host
# `nixos-rebuild switch --flake .#<host> --target-host z@<host>.internal
# --use-remote-sudo` invocations documented in each host's DEPLOY.md/README.
#
# Deliberately a plain `colmena = {...}` flake output (imported here, wired
# in by flake.nix), NOT the newer `colmenaHive = colmena.lib.makeHive {...}`
# form — that form needs `colmena` itself added as a flake input just to get
# at `colmena.lib`, purely to build the hive attrset. The CLI has detected a
# bare top-level `colmena` output on its own since 0.1 and still does as of
# the version current when this was written (2026-08) — no extra input, no
# extra pin to keep in sync with nixpkgs.
#
# Why this isn't just `nixosConfigurations` reused verbatim: Colmena evaluates
# each node from a plain module list plus its own `deployment.*` options
# module — it has no way to import an already-built `nixpkgs.lib.nixosSystem`
# result (that's a finished, evaluated config, not a re-importable module).
# So each node below re-lists the same modules flake.nix's
# `nixosConfigurations.<host>` already uses. This is the one bit of
# unavoidable duplication — if a host's module list changes in flake.nix
# (a new nixos-hardware profile, a new shared HM module, …), mirror the
# change here too. Everything each module actually *contains*
# (hosts/<host>/configuration.nix, home.nix, hardware-configuration.nix) is
# still owned by exactly one file, same as before.
{ self, nixpkgs, home-manager, sops-nix, nixos-hardware, dank-material-shell, plasma-manager, niri-flake, claude-desktop-debian, nixpkgs-orca-slicer, nixpkgs-bambu-studio }:

{
  meta = {
    description = "zjones homelab fleet";

    # Default nixpkgs for the hive — x86_64-linux, matching most of the fleet.
    # hopper/hamilton (aarch64-linux Pis) override this below via
    # `nodeNixpkgs`, the same way flake.nix's `nixosConfigurations.hopper`/
    # `.hamilton` pass `system = "aarch64-linux"` while everyone else passes
    # `"x86_64-linux"`.
    nixpkgs = import nixpkgs { system = "x86_64-linux"; };
    nodeNixpkgs = {
      hopper = import nixpkgs { system = "aarch64-linux"; };
      hamilton = import nixpkgs { system = "aarch64-linux"; };
    };

    # Every host imports modules/nixos/common.nix -> motd.nix, which reads
    # `self.rev`/`self.dirtyRev` for the MOTD's build-revision line — without
    # this, evaluation fails with "attribute 'self' missing" (hit for real
    # during pegasus's initial install, see hosts/pegasus/HANDOFF.md). Mirrors
    # flake.nix's `specialArgs = { inherit self; };` on every
    # `nixosSystem` call.
    specialArgs = { inherit self; };

    # ── Distributed builds: hopper/hamilton's aarch64 closures build on
    # pegasus, not the machine running `colmena apply` ────────────────────────
    # This is Nix's own distributed-build mechanism (the same one
    # `nixos-rebuild switch --build-host` already used, pointed at
    # memory-alpha, before this migration) — meta.machinesFile is passed
    # straight through as `--builders @<file>` to the underlying `nix-store`
    # calls. It is NOT `deployment.buildOnTarget`: that option builds ON the
    # target node itself, which for hopper/hamilton would mean compiling on
    # the Pi — exactly what emulated cross-building on a faster x86_64 box
    # (previously memory-alpha, now pegasus — it has the most CPU/RAM in the
    # fleet) exists to avoid.
    #
    # Using this requires the *user running `colmena apply`* to be a
    # `nix.settings.trusted-users` entry on whichever machine they run it
    # from — untrusted users aren't allowed to point Nix at arbitrary
    # `--builders`. See modules/nixos/common.nix, which now sets this
    # fleet-wide for `z`. (serenity/nix-darwin runs Determinate Nix with
    # `nix.enable = false`, so this repo can't set it there — see the open
    # question in the PR description if `colmena apply` is meant to run from
    # the Mac.)
    machinesFile = ./colmena-builders.machines;
  };

  # ── memory-alpha ────────────────────────────────────────────────────────────
  memory-alpha = {
    deployment = {
      targetHost = "memory-alpha.internal";
      targetUser = "z";
      tags = [ "fleet" ];
    };
    imports = [
      ./hosts/memory-alpha/configuration.nix
      home-manager.nixosModules.home-manager
      sops-nix.nixosModules.sops
    ];
  };

  # ── pegasus ─────────────────────────────────────────────────────────────────
  # Mirrors flake.nix's `nixosConfigurations.pegasus` module list exactly,
  # including the DankMaterialShell module and the HM sharedModules/
  # extraSpecialArgs/backupFileExtension block — pegasus's home.nix imports
  # niri-settings.nix and reaches for `claudeDesktop`/`orcaSlicerNewer`/
  # `bambuStudioNewer`, all of which only exist via that block. Omitting it
  # here would make `colmena apply --on pegasus` build a materially different
  # (broken) closure than `nixos-rebuild switch --flake .#pegasus` does.
  pegasus = {
    deployment = {
      targetHost = "pegasus.internal";
      targetUser = "z";
      tags = [ "fleet" ];
    };
    imports = [
      ./hosts/pegasus/configuration.nix
      home-manager.nixosModules.home-manager
      sops-nix.nixosModules.sops
      dank-material-shell.nixosModules.dank-material-shell
      {
        home-manager.sharedModules = [
          plasma-manager.homeModules.plasma-manager
          niri-flake.homeModules.config
        ];
        home-manager.extraSpecialArgs = {
          claudeDesktop = claude-desktop-debian.packages.x86_64-linux.claude-desktop-fhs;
          orcaSlicerNewer = nixpkgs-orca-slicer.legacyPackages.x86_64-linux.orca-slicer;
          bambuStudioNewer =
            (import nixpkgs-bambu-studio {
              system = "x86_64-linux";
              config.allowUnfree = true;
            }).bambu-studio.override
              {
                withNvidiaGLWorkaround = true;
              };
        };
        home-manager.backupFileExtension = "pre-declarative-niri-config";
      }
    ];
  };

  # ── galactica — NOT YET IN THE HIVE ───────────────────────────────────────
  # There is no `hosts/galactica/configuration.nix` and no
  # `nixosConfigurations.galactica` in flake.nix as of this writing —
  # hosts/galactica/README.md is explicit that this is deliberate (the
  # storage layout isn't settled yet; see its DECISIONS.md decision 3). This
  # file can't reference a module that doesn't exist, so there's no galactica
  # node below, and `colmena apply`/`--on @fleet` today really does mean
  # "all four real hosts" — there's no fifth one being silently skipped.
  #
  # Once `hosts/galactica/configuration.nix` and `nixosConfigurations.
  # galactica` land, add its node here in the same shape as the others:
  #
  #   galactica = {
  #     deployment = {
  #       # tower.internal, NOT galactica.internal — the AdGuard rewrite that
  #       # keeps the old Tower/Unraid hostname resolving to this box is the
  #       # fleet's actual DNS story for it (see galactica's DECISIONS.md
  #       # decision on naming); nothing answers to `galactica.internal`.
  #       targetHost = "tower.internal";
  #       targetUser = "z";
  #       # Deliberately NOT tagged "fleet": galactica is periodically
  #       # LUKS-locked at boot (initrd SSH unlock on :2222 — see
  #       # scripts/luks-unlock-remote.sh / the `unlock-tower` aliases), and
  #       # plain SSH to :22 simply times out until someone unlocks it —
  #       # expected, not a deploy failure. `colmena apply --on @fleet`
  #       # then skips it for exactly that reason; deploy to it explicitly
  #       # (`colmena apply --on galactica`, or `--on @luks-locked`) once
  #       # it's confirmed unlocked and reachable.
  #       tags = [ "luks-locked" ];
  #     };
  #     imports = [
  #       ./hosts/galactica/configuration.nix
  #       home-manager.nixosModules.home-manager
  #       sops-nix.nixosModules.sops
  #     ];
  #   };

  # ── hopper (Raspberry Pi 4) ─────────────────────────────────────────────────
  hopper = {
    deployment = {
      targetHost = "hopper.internal";
      targetUser = "z";
      tags = [ "fleet" ];
    };
    imports = [
      nixos-hardware.nixosModules.raspberry-pi-4
      "${nixpkgs}/nixos/modules/installer/sd-card/sd-image-aarch64.nix"
      ./hosts/hopper/configuration.nix
      home-manager.nixosModules.home-manager
      sops-nix.nixosModules.sops
    ];
  };

  # ── hamilton (Raspberry Pi 3) ───────────────────────────────────────────────
  hamilton = {
    deployment = {
      targetHost = "hamilton.internal";
      targetUser = "z";
      tags = [ "fleet" ];
    };
    imports = [
      nixos-hardware.nixosModules.raspberry-pi-3
      "${nixpkgs}/nixos/modules/installer/sd-card/sd-image-aarch64.nix"
      ./hosts/hamilton/configuration.nix
      home-manager.nixosModules.home-manager
      sops-nix.nixosModules.sops
    ];
  };
}

# ── Running it ───────────────────────────────────────────────────────────────
#   colmena apply --on @fleet    # routine deploy — every host in the hive
#   colmena apply                # same, today — no untagged host to skip yet
#   colmena apply --on pegasus   # single host, by name (globs work too: hop*)
#
# `--on` only supports positive selection (names, globs, `@tag`) — Colmena has
# no `!host`/negation syntax as of the version current when this was written
# (2026-08). `@fleet` vs plain `colmena apply` are equivalent right now (every
# node is tagged `fleet`) but stop being equivalent the moment galactica's
# node is added above with the `luks-locked` tag instead — at that point
# `--on @fleet` becomes the routine, galactica-skipping command and plain
# `colmena apply` starts trying (and, until unlocked, failing) to reach it
# too. Reach for `@fleet` by habit once that lands.
