{
  description = "zjones homelab NixOS configuration";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";

    home-manager = {
      url = "github:nix-community/home-manager/release-26.05";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    sops-nix = {
      url = "github:Mic92/sops-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # Hardware profiles for the Raspberry Pis. Both hopper (Pi 4) and hamilton
    # (Pi 3) use these profiles plus nixpkgs' generic aarch64 sd-image module,
    # which boots via u-boot on the mainline kernel — and the mainline kernel
    # is in cache.nixos.org, so the images build without compiling a kernel.
    # (We deliberately avoid raspberry-pi-nix: its downstream kernel isn't
    # cached, forcing a multi-hour emulated compile on every bump.)
    nixos-hardware.url = "github:NixOS/nixos-hardware";

    # nix-darwin for the Mac (Serenity). nix-darwin uses release branches that
    # must match the nixpkgs release — nix-darwin-26.05 pairs with nixpkgs 26.05
    # (master is a newer release and is rejected by nix-darwin's release check).
    nix-darwin = {
      url = "github:nix-darwin/nix-darwin/nix-darwin-26.05";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # Declarative KDE Plasma via Home Manager (used on pegasus).
    plasma-manager = {
      url = "github:nix-community/plasma-manager";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.home-manager.follows = "home-manager";
    };

    # Claude Desktop (used on pegasus). Anthropic shipped an official Linux
    # beta (.deb, own apt repo) on 2026-06-30 but hasn't reached nixpkgs yet
    # (too recent). This flake repackages that *official* .deb for Nix as of
    # its v3.0.0 — not the older community approach of patching the Windows/
    # macOS build to run on Linux. See hosts/pegasus/DECISIONS.md.
    # git+https rather than github: — this session's GitHub access is
    # scoped to zjones-xyz/nixos-config only, so the github: tarball-API
    # fetch 403s here (though it works fine anywhere with normal GitHub
    # access, e.g. on pegasus itself). git+https uses plain git protocol
    # instead, unaffected either way — see .claude/hooks/flake-check-sandboxed.sh
    # for the same workaround applied to the other inputs.
    claude-desktop-debian = {
      url = "git+https://github.com/aaddrick/claude-desktop-debian.git";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # DankMaterialShell (used on pegasus, layered on Niri) — a Quickshell-based
    # desktop shell, not in nixpkgs. Quickshell itself IS in nixpkgs 26.05
    # (0.3.0, meets DMS's stated minimum) so no separate quickshell input is
    # needed — only DMS's own flake, for its NixOS module and package build.
    # git+https rather than github: for the same sandboxed-GitHub-access
    # reason as claude-desktop-debian above.
    dank-material-shell = {
      url = "git+https://github.com/AvengeMedia/DankMaterialShell.git";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # niri-flake (used on pegasus) — used ONLY for its homeModules.config,
    # which provides `programs.niri.settings` (declarative, KDL-validated at
    # build time) as a home-manager option. Deliberately NOT using
    # niri-flake's nixosModules.niri: that module fully disables nixpkgs'
    # own programs.niri module and installs niri-flake's own from-source
    # build instead — a bigger swap than intended here, and, checked
    # 2026-08-11, actually a downgrade at the moment (niri-flake's "stable"
    # track is pinned to v25.08; nixpkgs 26.05 already ships niri 26.04).
    # See hosts/pegasus/DECISIONS.md.
    niri-flake = {
      url = "github:sodiboo/niri-flake";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # nixflix (used on galactica) — the declarative *arr media stack. Points
    # at UPSTREAM, not at our zjones-xyz/nixflix-exp fork, and that is the
    # canary-pattern split rather than an accident: the fork's job is to merge
    # each upstream revision, prove it against nixos-26.05 in its own CI, and
    # only then is this lock bumped to the matching upstream rev. The fork
    # validates; upstream is what actually deploys.
    #
    # This did briefly point at the fork, to pick up seven robustness fixes it
    # carries that upstream has not taken yet. Two things sent it back here:
    #
    #  1. The fork is a PRIVATE repo, so CI — a bare actions/checkout runner
    #     whose token is scoped to this repository — cannot fetch it at all.
    #     Older Nix reports that inaccessible remote as "Cannot find Git
    #     revision ... in ref ...", which reads like a stale pin and is not:
    #     the ref is correct and carries exactly that rev, the runner simply
    #     has no access. (`allRefs=1` does not help, for the same reason.)
    #  2. Checked against galactica's actual configuration, not one of those
    #     seven fixes changes what this host deploys. Every one is either
    #     confined to the fork's `tests/` tree or gated behind a service this
    #     host does not enable — jellyfin, seerr, navidrome, flaresolverr and
    #     recyclarr are all `false` in hosts/galactica/nixflix.nix. They are
    #     what makes the *canary's* CI reliable, which is where they belong.
    #
    # ⚠ The one to remember is the FlareSolverr readiness-probe fix. If
    # `nixflix.flaresolverr.enable` is ever turned on here while upstream
    # still lacks it, one slow boot can fail the 30s probe and leave
    # prowlarr-indexer-proxies permanently unconfigured — systemd cancels it
    # with result 'dependency' and never re-queues it, so it presents as
    # indexer proxies that simply never appear. Upstream that fix (or point
    # back at the fork, public by then) before enabling FlareSolverr.
    #
    # `follows` on nixpkgs is what governs galactica's packages either way: a
    # NixOS module always evaluates against the *consuming* host's pkgs, so
    # upstream tracking nixos-unstable is irrelevant here — these modules get
    # this fleet's 26.05 pin, which is exactly what the fork's CI rehearses.
    #
    # Pinned to an exact rev rather than tracking `main`, and the rev is not
    # upstream's tip: `c5b5944` is the revision the canary has actually proven
    # against 26.05 (zjones-xyz/nixflix-exp#1 is that tree, CI green). Upstream
    # commits most days, so a bare branch URL would let `nix flake update` pull
    # an unvalidated revision into the fleet — which is the exact failure the
    # canary exists to prevent. Bumping this is a deliberate step: merge
    # upstream into the fork, let its CI prove the result against 26.05, then
    # move this rev to match. Same rev-pinning shape as the two standalone
    # nixpkgs inputs below.
    #
    # git+https rather than github: — see the claude-desktop-debian input
    # comment above for why.
    nixflix = {
      url = "git+https://github.com/kiriwalawren/nixflix.git?rev=c5b5944791ecbc2a434fbf6d8d95859aee47b3b9&shallow=1";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # A second, standalone nixpkgs — deliberately NOT inputs.nixpkgs.follows,
    # unlike every other input above — pinned only to pull a newer
    # `orca-slicer` (used on pegasus) than the one in the main `nixpkgs`
    # input above. The main nixpkgs is locked well before nixpkgs bumped
    # orca-slicer 2.3.1 -> 2.3.2 (2026-03-23); this pins exactly that bump
    # commit rather than a moving branch HEAD, so the diff here is nothing
    # but that one already-vetted version bump. Moving the *shared* nixpkgs
    # input instead was considered and rejected for the same reason as the
    # Bambu Studio NVIDIA-GL fix (see hosts/pegasus/DECISIONS.md): it's a
    # single input shared by every host in the fleet, so bumping it would
    # move package versions fleet-wide just for one desktop app on one host.
    # git+https rather than github: — see the claude-desktop-debian input
    # comment above for why.
    nixpkgs-orca-slicer.url = "git+https://github.com/NixOS/nixpkgs.git?rev=e749b91730e1d4c612294f1e10dd351674d697fa&shallow=1";

    # Same idea as nixpkgs-orca-slicer above, for bambu-studio: the main
    # nixpkgs pin has it at 02.03.01.51 with the NVIDIA-GL fix hand-applied
    # via overrideAttrs (hosts/pegasus/home.nix). This pins the commit where
    # nixpkgs both bumped it to 02.05.00.67 *and* already carries the real
    # upstream withNvidiaGLWorkaround package arg (nixpkgs#522161) — so this
    # replaces the hand-rolled overrideAttrs fix with the real thing, plus
    # picks up two extra version bumps (02.04.00.70, 02.05.00.67).
    nixpkgs-bambu-studio.url = "git+https://github.com/NixOS/nixpkgs.git?rev=13b979d75662827615c1de6dd22f87e6296ba71d&shallow=1";
  };

  outputs = { self, nixpkgs, home-manager, sops-nix, nixos-hardware, nix-darwin, plasma-manager, claude-desktop-debian, dank-material-shell, niri-flake, nixflix, nixpkgs-orca-slicer, nixpkgs-bambu-studio, ... }:
  {
    nixosConfigurations = {
      memory-alpha = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        specialArgs = { inherit self; };
        modules = [
          ./hosts/memory-alpha/configuration.nix
          home-manager.nixosModules.home-manager
          sops-nix.nixosModules.sops
        ];
      };

      # pegasus — AM4 Ryzen + RTX 4070 workstation: gaming desktop (Plasma 6 /
      # Wayland) and the primary GPU inference endpoint (ollama + Olla router).
      # Single NVMe, installed via hosts/pegasus/disko.nix (2026-07-11).
      pegasus = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        specialArgs = { inherit self; };
        modules = [
          ./hosts/pegasus/configuration.nix
          home-manager.nixosModules.home-manager
          sops-nix.nixosModules.sops
          dank-material-shell.nixosModules.dank-material-shell
          {
            # Make plasma-manager's and niri-flake's HM options available to
            # hosts/pegasus/home.nix (niri-flake's homeModules.config is
            # ONLY the declarative-config layer — see the niri-flake input
            # comment above for why not its full nixosModules.niri).
            home-manager.sharedModules = [
              plasma-manager.homeModules.plasma-manager
              niri-flake.homeModules.config
            ];
            # claude-desktop-debian has no HM module, just a package — pass it
            # through directly rather than adding it as a NixOS-level overlay.
            # orcaSlicerNewer/bambuStudioNewer are the same idea, from the
            # standalone nixpkgs-orca-slicer/nixpkgs-bambu-studio inputs above
            # (see their comments for why they're separate nixpkgs rather than
            # an overlay on the shared one). withNvidiaGLWorkaround is the
            # real upstream fix (nixpkgs#522161) baked into that pin — see
            # hosts/pegasus/home.nix and DECISIONS.md.
            home-manager.extraSpecialArgs = {
              claudeDesktop = claude-desktop-debian.packages.x86_64-linux.claude-desktop-fhs;
              orcaSlicerNewer = nixpkgs-orca-slicer.legacyPackages.x86_64-linux.orca-slicer;
              # bambu-studio is unfree (agpl3Plus + unfree, marked as of the
              # pinned commit) — legacyPackages defaults to allowUnfree =
              # false, unlike the main `nixpkgs` above (set globally via
              # modules/nixos/common.nix), so this needs its own pkgs import
              # rather than plain legacyPackages.
              bambuStudioNewer =
                (import nixpkgs-bambu-studio {
                  system = "x86_64-linux";
                  config.allowUnfree = true;
                }).bambu-studio.override
                  {
                    withNvidiaGLWorkaround = true;
                  };
            };
            # Niri's own auto-generated ~/.config/niri/config.kdl (a plain,
            # not-home-manager-owned file, hand-edited in place during Niri
            # bring-up — see hosts/pegasus/MANUAL-STEPS.md §16) now collides
            # with home-manager's declarative management of that same path
            # (niri-settings.nix, via niri-flake's homeModules.config).
            # Without this, activation would abort rather than overwrite a
            # file it doesn't already own. Matches the pattern already used
            # for serenity's pre-existing dotfiles.
            home-manager.backupFileExtension = "pre-declarative-niri-config";
          }
        ];
      };

      # galactica — Tower, bare-metal NixOS (replacing Unraid). Root: LUKS +
      # btrfs on the NVMe, installed via hosts/galactica/disko.nix (2026-08-31).
      # The RAIDZ1 media array is a separate, later addition once it's built
      # live — not part of this closure yet. See hosts/galactica/README.md
      # and MANUAL-STEPS.md for what's still outstanding.
      galactica = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        specialArgs = { inherit self; };
        modules = [
          ./hosts/galactica/configuration.nix
          home-manager.nixosModules.home-manager
          sops-nix.nixosModules.sops
          # Brings in nixflix's own modules AND vpn-confinement (nixflix's
          # nixosModules.default imports it), which is what provides the
          # `vpnNamespaces` options and the per-service `vpnConfinement`
          # option that hosts/galactica/nixflix.nix uses for the NAT-PMP
          # sidecar. The stack's own configuration lives in that file, which
          # configuration.nix imports.
          nixflix.nixosModules.default
        ];
      };

      # hopper — Raspberry Pi 4, network-core node. Uses nixos-hardware's rpi-4
      # profile plus nixpkgs' generic sd-image-aarch64 builder (mainline kernel,
      # cached — see the nixos-hardware input comment above).
      #
      # Bootstrap: build the SD image on memory-alpha (aarch64 via binfmt) and
      # flash it — boots straight into this config. See hosts/hopper/DEPLOY.md.
      #   nix build .#nixosConfigurations.hopper.config.system.build.sdImage
      # Routine deploys, with memory-alpha as the aarch64 build host:
      #   nixos-rebuild switch --flake .#hopper \
      #     --target-host z@hopper.internal \
      #     --build-host z@memory-alpha.internal --use-remote-sudo
      hopper = nixpkgs.lib.nixosSystem {
        system = "aarch64-linux";
        specialArgs = { inherit self; };
        modules = [
          nixos-hardware.nixosModules.raspberry-pi-4
          "${nixpkgs}/nixos/modules/installer/sd-card/sd-image-aarch64.nix"
          ./hosts/hopper/configuration.nix
          home-manager.nixosModules.home-manager
          sops-nix.nixosModules.sops
        ];
      };

      # hamilton — Raspberry Pi 3 (bcm2837), backup AdGuard/Unbound resolver.
      # Same approach as hopper: nixos-hardware's rpi-3 profile plus nixpkgs'
      # sd-image-aarch64 builder (SD-card boot).
      #
      # Bootstrap: build the SD image on memory-alpha (aarch64 via binfmt) and
      # flash it — boots straight into this config. See hosts/hamilton/DEPLOY.md.
      #   nix build .#nixosConfigurations.hamilton.config.system.build.sdImage
      # Routine deploys, with memory-alpha as the aarch64 build host:
      #   nixos-rebuild switch --flake .#hamilton \
      #     --target-host z@hamilton.internal \
      #     --build-host z@memory-alpha.internal --use-remote-sudo
      hamilton = nixpkgs.lib.nixosSystem {
        system = "aarch64-linux";
        specialArgs = { inherit self; };
        modules = [
          nixos-hardware.nixosModules.raspberry-pi-3
          "${nixpkgs}/nixos/modules/installer/sd-card/sd-image-aarch64.nix"
          ./hosts/hamilton/configuration.nix
          home-manager.nixosModules.home-manager
          sops-nix.nixosModules.sops
        ];
      };

      # galactica-live-iso — throwaway live ISO for Tower's bare metal, built
      # to de-risk the migration plan (boot test, mounting the Unraid array
      # read-only, hardware profile) BEFORE galactica has a real config — see
      # hosts/galactica/README.md (no configuration.nix yet, deliberately) and
      # hosts/galactica/live-iso.nix for the build/flash commands. This is not
      # nixosConfigurations.galactica and never becomes the real host.
      galactica-live-iso = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        modules = [
          "${nixpkgs}/nixos/modules/installer/cd-dvd/installation-cd-minimal.nix"
          ./hosts/galactica/live-iso.nix
        ];
      };
    };

    # ── Darwin (macOS) ──────────────────────────────────────────────────────
    # Serenity — Zoe's Mac. Shares modules/home/common.nix with the Linux hosts
    # via Home Manager. Build/activate on the Mac with:
    #   nix run nix-darwin -- switch --flake .#serenity
    # nix.enable = false in the host config so it coexists with Determinate Nix.
    darwinConfigurations.serenity = nix-darwin.lib.darwinSystem {
      system = "aarch64-darwin";
      modules = [
        ./hosts/serenity/configuration.nix
        home-manager.darwinModules.home-manager
        {
          home-manager.useGlobalPkgs = true;
          home-manager.useUserPackages = true;
          # Back up pre-existing dotfiles HM would otherwise refuse to clobber
          # (e.g. the Mac's hand-written ~/.zshrc → ~/.zshrc.before-nix-darwin).
          home-manager.backupFileExtension = "before-nix-darwin";
          home-manager.users.z = import ./hosts/serenity/home.nix;
        }
      ];
    };
  };
}
