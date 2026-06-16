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
      # Deploy from a build host with:
      #   nixos-rebuild switch --flake .#hopper \
      #     --target-host z@hopper.internal --use-remote-sudo
      # (build natively on the Pi, or add --build-host for a remote/cross build).
      hopper = nixpkgs.lib.nixosSystem {
        system = "aarch64-linux";
        modules = [
          raspberry-pi-nix.nixosModules.raspberry-pi
          ./hosts/hopper/configuration.nix
          home-manager.nixosModules.home-manager
          sops-nix.nixosModules.sops
        ];
      };

      # pi3 — Raspberry Pi 3 (bcm2837), backup AdGuard/Unbound resolver.
      # Placeholder name; rename once the unit is in hand. raspberry-pi-nix
      # doesn't support the Pi 3, so this uses nixos-hardware's rpi-3 profile
      # plus nixpkgs' sd-image-aarch64 builder (SD-card boot).
      #
      # Build the SD image with:
      #   nix build .#nixosConfigurations.pi3.config.system.build.sdImage
      pi3 = nixpkgs.lib.nixosSystem {
        system = "aarch64-linux";
        modules = [
          nixos-hardware.nixosModules.raspberry-pi-3
          "${nixpkgs}/nixos/modules/installer/sd-card/sd-image-aarch64.nix"
          ./hosts/pi3/configuration.nix
          home-manager.nixosModules.home-manager
          sops-nix.nixosModules.sops
        ];
      };
    };
  };
}
