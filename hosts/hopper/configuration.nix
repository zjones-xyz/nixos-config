{ config, pkgs, lib, ... }:

{
  imports = [
    ../../modules/nixos/common.nix
    ../../modules/nixos/rpi-common.nix
    ../../modules/nixos/tailscale.nix
    ../../modules/nixos/dns.nix
    ../../modules/nixos/nut.nix
    ../../modules/nixos/beszel.nix
    ../../modules/nixos/uptime-kuma.nix
    ../../modules/nixos/ntfy.nix
    ../../modules/nixos/homepage.nix
    ../../modules/nixos/speedtest-tracker.nix
    ../../modules/nixos/traefik-local.nix
  ];

  networking.hostName = "hopper";
  # DHCP reservation on the GL.iNet router is the source of truth for hopper's
  # IP — we don't pin a static address here. NetworkManager + DHCP is enough.
  networking.networkmanager.enable = true;

  # ── Raspberry Pi 4 ──────────────────────────────────────────────────────────
  # Board support comes from nixos-hardware's raspberry-pi-4 profile plus
  # nixpkgs' sd-image-aarch64 module (wired up in flake.nix). These supply
  # u-boot and the SD partition layout — there is no nixos-generate-config
  # hardware-configuration.nix on the Pi. Booting is from the SD card.
  # The mainline-kernel pin lives in the shared rpi-common.nix.

  # ── sops-nix ──────────────────────────────────────────────────────────────
  # Uses the host's SSH ed25519 key as the age identity. After first boot:
  #   ssh-to-age < /etc/ssh/ssh_host_ed25519_key.pub
  # then put that pubkey in .sops.yaml (replacing the hopper placeholder) and
  #   sops updatekeys secrets/hopper.yaml
  sops = {
    defaultSopsFile = ../../secrets/hopper.yaml;
    age.sshKeyPaths = [ "/etc/ssh/ssh_host_ed25519_key" ];
  };

  # ── home-manager ──────────────────────────────────────────────────────────
  home-manager = {
    useGlobalPkgs = true;
    useUserPackages = true;
    users.z = import ./home.nix;
  };

  system.stateVersion = "26.05";
}
