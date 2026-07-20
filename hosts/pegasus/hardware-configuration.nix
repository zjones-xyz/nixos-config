# ─────────────────────────────────────────────────────────────────────────────
# Real hardware config, reconciled 2026-07-11 after installing via disko.nix
# onto the single NVMe (PNY CS3250 2TB; CachyOS's drive was removed — see
# DECISIONS.md). Module list from `nixos-generate-config --no-filesystems`;
# UUIDs from `lsblk -f` against the disko-driven layout.
# ─────────────────────────────────────────────────────────────────────────────
{ config, lib, pkgs, modulesPath, ... }:

{
  imports = [ (modulesPath + "/installer/scan/not-detected.nix") ];

  boot.initrd.availableKernelModules = [ "xhci_pci" "ahci" "nvme" "usbhid" "usb_storage" "sd_mod" ];
  boot.initrd.kernelModules = [ ];
  boot.kernelModules = [ "kvm-amd" ];
  boot.extraModulePackages = [ ];

  # ── BTRFS subvolumes on a LUKS container ─────────────────────────────────
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

  # ── microVM agent-sandbox persistent volumes (docs/microvm-sandbox) ───────
  # Two dedicated subvolumes, siblings of @snapshots/@games: one for the
  # guest's writable-store-overlay image (churny build artifacts, never
  # snapshotted), one for its /persist state image (SSH host key = its sops
  # age identity, agent home, Docker data — this is what btrbk snapshots).
  # MANUAL STEP before the first `nixos-rebuild switch` that picks this up:
  # `btrfs subvolume create` both on the real disk — see
  # docs/microvm-sandbox/MANUAL-STEPS.md.
  #
  # `nofail` (2026-07-21, live incident): before the subvolumes existed on
  # disk, these two mounts were treated as required-for-boot by default —
  # Pegasus dropped into emergency mode waiting on a mount that could never
  # succeed, taking the *entire host* down with it, not just the sandbox.
  # A missing/broken sandbox volume should never be able to hold the whole
  # workstation's boot hostage.
  fileSystems."/var/lib/microvms/agent-sandbox-store" = {
    device = "/dev/mapper/cryptroot";
    fsType = "btrfs";
    options = [ "subvol=@microvm-store" "compress=zstd" "noatime" "nofail" ];
  };

  fileSystems."/var/lib/microvms/agent-sandbox-state" = {
    device = "/dev/mapper/cryptroot";
    fsType = "btrfs";
    options = [ "subvol=@microvm-state" "compress=zstd" "noatime" "nofail" ];
  };

  boot.initrd.luks.devices."cryptroot" = {
    device = "/dev/disk/by-uuid/be8611f1-dc26-4197-bc1c-4772af1a0880";
    # Matches disko.nix's settings.allowDiscards = true — lets fstrim.enable
    # (modules/nixos/performance.nix) actually pass TRIM through to the NVMe.
    allowDiscards = true;
  };

  fileSystems."/boot" = {
    device = "/dev/disk/by-uuid/FCCA-8FEB";
    fsType = "vfat";
    options = [ "fmask=0077" "dmask=0077" ];
  };

  swapDevices = [ ]; # zram provides swap — see modules/nixos/performance.nix

  nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";
  hardware.cpu.amd.updateMicrocode = lib.mkDefault config.hardware.enableRedistributableFirmware;
}
