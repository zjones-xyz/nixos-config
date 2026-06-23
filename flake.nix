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
  };

  outputs = { self, nixpkgs, home-manager, sops-nix, nixos-hardware, nix-darwin, ... }: {
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
      # Migrated from CachyOS onto the stock latest kernel + scx schedulers.
      # NOTE: hosts/pegasus/hardware-configuration.nix is a PLACEHOLDER — the
      # real one must be generated on the machine (or driven by
      # hosts/pegasus/disko.nix) before deploying. See hosts/pegasus/MANUAL-STEPS.md.
      pegasus = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        modules = [
          ./hosts/pegasus/configuration.nix
          home-manager.nixosModules.home-manager
          sops-nix.nixosModules.sops
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
