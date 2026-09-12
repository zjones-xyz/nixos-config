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
    nixos-hardware = {
      url = "github:NixOS/nixos-hardware";
      inputs.nixpkgs.follows = "nixpkgs";
    };

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

    # Claude Desktop (used on pegasus). Repackages Anthropic's *official*
    # Linux .deb — not the old community patch of the Windows/macOS build.
    # See hosts/pegasus/DECISIONS.md.
    # git+https rather than github: — sandboxed web sessions can't use the
    # github: tarball API (403 under scoped access), while plain git protocol
    # works everywhere. The same applies to every git+https input below, and
    # .claude/hooks/flake-check-sandboxed.sh applies it to the rest.
    claude-desktop-debian = {
      url = "git+https://github.com/aaddrick/claude-desktop-debian.git";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # DankMaterialShell (used on pegasus, layered on Niri) — a Quickshell-based
    # desktop shell, not in nixpkgs. Quickshell itself IS in nixpkgs 26.05
    # (0.3.0, meets DMS's stated minimum) so no separate quickshell input is
    # needed — only DMS's own flake, for its NixOS module and package build.
    dank-material-shell = {
      url = "git+https://github.com/AvengeMedia/DankMaterialShell.git";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # zen-browser (used on pegasus) — Zen has no nixpkgs package at all (not
    # even a removed/replaced stub, unlike opera-flake below). This is the
    # community flake nixpkgs' own PR discussions point to; `beta` is its
    # `packages.default`. git+https rather than github: — see
    # claude-desktop-debian above for why.
    zen-browser = {
      url = "git+https://github.com/0xc000022070/zen-browser-flake.git";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # Opera (used on pegasus) — nixpkgs removed `opera` outright ("lack of
    # maintenance"); this is the same derivation ported into its own
    # community-maintained flake by one of opera's former nixpkgs
    # maintainers. git+https rather than github: — see claude-desktop-debian
    # above for why.
    opera-flake = {
      url = "git+https://github.com/YisuiDenghua/opera-flake.git";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # niri-flake (used on pegasus) — ONLY for its homeModules.config, which
    # provides `programs.niri.settings` (declarative, KDL-validated at build
    # time). Deliberately NOT its nixosModules.niri: that fully disables
    # nixpkgs' own programs.niri module and installs niri-flake's from-source
    # build instead — a bigger swap than intended, and an older niri than
    # nixpkgs ships. See hosts/pegasus/DECISIONS.md.
    niri-flake = {
      url = "github:sodiboo/niri-flake";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.nixpkgs-stable.follows = "nixpkgs";
    };

    # nixflix (galactica) — the declarative *arr media stack. Points at
    # UPSTREAM, pinned to the exact rev the zjones-xyz/nixflix-exp canary has
    # proven against 26.05 — never a branch URL, or a routine `nix flake
    # update` pulls an unrehearsed revision. Bump = merge upstream into the
    # fork, let its CI go green against 26.05, then move this rev to match.
    #
    # ⚠ Carried debt: the fork is private, CI cannot fetch it, and three of
    # its fixes this host needs are therefore re-applied by hand in
    # hosts/galactica/nixflix.nix. DECISIONS.md §10 has the full argument and
    # the exit. git+https rather than github: — see claude-desktop-debian.
    nixflix = {
      url = "git+https://github.com/kiriwalawren/nixflix.git?rev=c5b5944791ecbc2a434fbf6d8d95859aee47b3b9&shallow=1";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # A second, standalone nixpkgs — deliberately NOT inputs.nixpkgs.follows —
    # pinned to exactly the commit that bumped `orca-slicer` (used on
    # pegasus), so the diff is that one vetted version bump and nothing else.
    # Bumping the *shared* nixpkgs instead would move package versions
    # fleet-wide for one desktop app on one host (hosts/pegasus/DECISIONS.md).
    nixpkgs-orca-slicer.url = "git+https://github.com/NixOS/nixpkgs.git?rev=e749b91730e1d4c612294f1e10dd351674d697fa&shallow=1";

    # Same idea as nixpkgs-orca-slicer above, for bambu-studio: the main
    # nixpkgs pin has it at 02.03.01.51 with the NVIDIA-GL fix hand-applied
    # via overrideAttrs (hosts/pegasus/home.nix). This pins the commit where
    # nixpkgs both bumped it to 02.05.00.67 *and* already carries the real
    # upstream withNvidiaGLWorkaround package arg (nixpkgs#522161) — so this
    # replaces the hand-rolled overrideAttrs fix with the real thing, plus
    # picks up two extra version bumps (02.04.00.70, 02.05.00.67).
    nixpkgs-bambu-studio.url = "git+https://github.com/NixOS/nixpkgs.git?rev=13b979d75662827615c1de6dd22f87e6296ba71d&shallow=1";

    # Non-flake theme sources for pegasus's Dragonized session, pinned here so
    # every source pin lives in flake.lock — consumed by
    # modules/nixos/desktop-dragonized.nix via specialArgs.
    dr460nized-src = {
      url = "git+https://gitlab.com/garuda-linux/themes-and-settings/settings/garuda-dr460nized.git?rev=35eb3abbc534f4046257c43ad9e05a9c010235cf&shallow=1";
      flake = false;
    };
    window-title-applet-src = {
      url = "git+https://github.com/dhruv8sh/plasma6-window-title-applet.git?rev=a6eaf5086a473919ed2fffc5d3b8d98237c2dd41&shallow=1";
      flake = false;
    };
  };

  outputs = { self, nixpkgs, home-manager, sops-nix, nixos-hardware, nix-darwin, plasma-manager, claude-desktop-debian, dank-material-shell, zen-browser, opera-flake, niri-flake, nixflix, nixpkgs-orca-slicer, nixpkgs-bambu-studio, dr460nized-src, window-title-applet-src, ... }:
  {
    formatter = {
      x86_64-linux = nixpkgs.legacyPackages.x86_64-linux.nixfmt-tree;
      aarch64-linux = nixpkgs.legacyPackages.aarch64-linux.nixfmt-tree;
      aarch64-darwin = nixpkgs.legacyPackages.aarch64-darwin.nixfmt-tree;
    };

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
        specialArgs = { inherit self dr460nized-src window-title-applet-src; };
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
              # Askimo (multi-LLM desktop chat client) — not in nixpkgs at
              # all, unlike claudeDesktop/orcaSlicerNewer/bambuStudioNewer
              # above (which are all upstream packages nixpkgs just hasn't
              # caught up to yet). pkgs/askimo.nix unpacks upstream's own
              # jpackage .deb release and runs it on nixpkgs' jdk25 — see
              # that file for why. callPackage against the main nixpkgs
              # rather than a pin: no version-skew concern since there's no
              # nixpkgs copy of this package to skew against.
              askimoDesktop = nixpkgs.legacyPackages.x86_64-linux.callPackage ./pkgs/askimo.nix { };
              # Zen and Opera: same "no HM module, just a package" shape as
              # claudeDesktop/askimoDesktop above — neither flake ships one.
              zenBrowser = zen-browser.packages.x86_64-linux.default;
              operaBrowser = opera-flake.packages.x86_64-linux.opera;
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
      # btrfs on the NVMe (disko.nix); the RAIDZ1 array `tank` and the media
      # stack are declared in hosts/galactica/. MANUAL-STEPS.md §12 tracks
      # what's still manual.
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

      # hopper — Raspberry Pi 4, network-core node (nixos-hardware rpi-4 +
      # sd-image builder). Build and deploy commands: hosts/hopper/DEPLOY.md.
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

      # hamilton — Raspberry Pi 3, backup AdGuard/Unbound resolver (same
      # shape as hopper). Build and deploy commands: hosts/hamilton/DEPLOY.md.
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

      # galactica-live-iso — throwaway live ISO built to de-risk the migration
      # (hosts/galactica/live-iso.nix has the build/flash commands). Not the
      # real host and never becomes it.
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
