# ─────────────────────────────────────────────────────────────────────────────
# PLACEHOLDER — regenerate with `nixos-generate-config` on the real machine.
# ─────────────────────────────────────────────────────────────────────────────
# Pegasus is not NixOS yet (currently CachyOS). This stub exists ONLY so the
# system closure evaluates and `nixos-rebuild build --flake .#pegasus` succeeds
# off the real hardware. The UUIDs below are fake. Do NOT deploy with this file:
# generate the real one on the box and commit it, OR drive the install with the
# disko spec in ./disko.nix (see hosts/pegasus/DECISIONS.md).
#
# Intended layout (mirrored by disko.nix): a single LUKS container on the NVMe
# holding a BTRFS filesystem with subvolumes @ @home @nix @snapshots @games.
{ config, lib, pkgs, modulesPath, ... }:

{
  imports = [ (modulesPath + "/installer/scan/not-detected.nix") ];

  # PLACEHOLDER module lists — regenerate on real hardware.
  boot.initrd.availableKernelModules = [ "nvme" "xhci_pci" "ahci" "usbhid" "usb_storage" "sd_mod" ];
  boot.initrd.kernelModules = [ ];
  boot.kernelModules = [ "kvm-amd" ];
  boot.extraModulePackages = [ ];

  # ── BTRFS subvolumes on a LUKS container (placeholder UUIDs) ────────────────
  fileSystems."/" = {
    device = "/dev/mapper/cryptroot";
    fsType = "btrfs";
    options = [ "subvol=@" "compress=zstd" "noatime" ];
  };

  fileSystems."/home" = {
    device = "/dev/mapper/cryptroot";
    fsType = "btrfs";
    options = [ "subvol=@home" "compress=zstd" "noatime" ];
  };

  fileSystems."/nix" = {
    device = "/dev/mapper/cryptroot";
    fsType = "btrfs";
    options = [ "subvol=@nix" "compress=zstd" "noatime" ];
  };

  fileSystems."/.snapshots" = {
    device = "/dev/mapper/cryptroot";
    fsType = "btrfs";
    options = [ "subvol=@snapshots" "compress=zstd" "noatime" ];
  };

  # Dedicated subvolume for the Steam library so it survives reinstalls.
  fileSystems."/games" = {
    device = "/dev/mapper/cryptroot";
    fsType = "btrfs";
    options = [ "subvol=@games" "compress=zstd" "noatime" ];
  };

  boot.initrd.luks.devices."cryptroot".device =
    "/dev/disk/by-uuid/00000000-0000-0000-0000-000000000000"; # PLACEHOLDER

  fileSystems."/boot" = {
    device = "/dev/disk/by-uuid/0000-0000"; # PLACEHOLDER (EFI system partition)
    fsType = "vfat";
    options = [ "fmask=0077" "dmask=0077" ];
  };

  swapDevices = [ ]; # zram provides swap — see modules/nixos/performance.nix

  nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";
  hardware.cpu.amd.updateMicrocode = lib.mkDefault config.hardware.enableRedistributableFirmware;
}
