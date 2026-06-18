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

    # Raspberry Pi board support (firmware, kernel, SD/USB image builder).
    # Supports Pi 4 (bcm2711) and Pi 5 (bcm2712) only — NOT the Pi 3.
    raspberry-pi-nix.url = "github:nix-community/raspberry-pi-nix";

    # Hardware profiles for older/other boards. Used for the Pi 3, which
    # raspberry-pi-nix doesn't cover; paired with nixpkgs' sd-image module.
    nixos-hardware.url = "github:NixOS/nixos-hardware";
  };

  outputs = { self, nixpkgs, home-manager, sops-nix, raspberry-pi-nix, nixos-hardware, ... }: {
    nixosConfigurations = {
      memory-alpha = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        modules = [
          ./hosts/memory-alpha/configuration.nix
          home-manager.nixosModules.home-manager
          sops-nix.nixosModules.sops
        ];
      };

      # hopper — Raspberry Pi 4 (bcm2711), network-core node.
      # Bootstrap: build the SD image on memory-alpha (aarch64 via binfmt) and
      # flash it — boots straight into this config. See hosts/hopper/DEPLOY.md.
      #   nix build .#nixosConfigurations.hopper.config.system.build.sdImage
      # Routine deploys, with memory-alpha as the aarch64 build host:
      #   nixos-rebuild switch --flake .#hopper \
      #     --target-host z@hopper.internal \
      #     --build-host z@memory-alpha.internal --use-remote-sudo
      hopper = nixpkgs.lib.nixosSystem {
        system = "aarch64-linux";
        modules = [
          raspberry-pi-nix.nixosModules.raspberry-pi
          raspberry-pi-nix.nixosModules.sd-image  # defines root fs + image partitions
          ./hosts/hopper/configuration.nix
          home-manager.nixosModules.home-manager
          sops-nix.nixosModules.sops
        ];
      };

      # hamilton — Raspberry Pi 3 (bcm2837), backup AdGuard/Unbound resolver.
      # raspberry-pi-nix doesn't support the Pi 3, so this uses nixos-hardware's
      # rpi-3 profile plus nixpkgs' sd-image-aarch64 builder (SD-card boot).
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
        modules = [
          nixos-hardware.nixosModules.raspberry-pi-3
          "${nixpkgs}/nixos/modules/installer/sd-card/sd-image-aarch64.nix"
          ./hosts/hamilton/configuration.nix
          home-manager.nixosModules.home-manager
          sops-nix.nixosModules.sops
        ];
      };
    };
  };
}
