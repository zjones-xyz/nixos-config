{ config, pkgs, lib, ... }:

{
  imports = [
    ./disk.nix
    ../../modules/nixos/common.nix
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
  # raspberry-pi-nix supplies the firmware, kernel, and bootloader; there is no
  # nixos-generate-config hardware-configuration.nix on the Pi.
  raspberry-pi-nix.board = "bcm2711";  # Pi 4 / CM4

  # Prefer booting from a USB SSD over the SD card — rebuilds churn writes and
  # SD cards wear out fast. Flash the image to the SSD and set the Pi's boot
  # order to USB-first (bootloader config / EEPROM). If you boot from SD, the
  # rootfs lives on the SD partition raspberry-pi-nix creates.
  #
  # The Pi 4 EEPROM boot order is configured outside NixOS (rpi-eeprom-config
  # or raspi-config on the vendor OS); see raspberry-pi-nix docs for setting
  # BOOT_ORDER=0xf41 (USB then SD).

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
