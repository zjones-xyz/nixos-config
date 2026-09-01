# ─────────────────────────────────────────────────────────────────────────────
# Real hardware config, reconciled 2026-08-31 after installing via disko.nix
# onto the SPCC 1TB NVMe (galactica's root) plus midden (the repurposed
# fastservices SSD, s-9545 — see disko.nix). Module list from
# `nixos-generate-config --no-filesystems`; UUIDs from `blkid` against the
# disko-driven layout. `mpt3sas` showed up in detection even with the HBA's
# drives (sidepool, the special-vdev candidates) physically disconnected —
# the controller itself still enumerates on the PCIe bus with nothing behind
# it; harmless, and useful to have already present for when those disks come
# back for the array build (MANUAL-STEPS.md §9).
# ─────────────────────────────────────────────────────────────────────────────
{ config, lib, pkgs, modulesPath, ... }:

{
  imports = [ (modulesPath + "/installer/scan/not-detected.nix") ];

  boot.initrd.availableKernelModules = [ "ehci_pci" "ahci" "nvme" "mpt3sas" "xhci_pci" "usbhid" "usb_storage" "sd_mod" ];
  boot.initrd.kernelModules = [ ];
  boot.kernelModules = [ "kvm-intel" ];
  boot.extraModulePackages = [ ];

  # ── Root: BTRFS subvolumes on a LUKS container (disko.nix: disk.main) ──────
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

  boot.initrd.luks.devices."cryptroot" = {
    device = "/dev/disk/by-uuid/0f3c74bc-87df-4c14-915f-c46741962b38";
    # Matches disko.nix's settings.allowDiscards = true — nixos-generate-config
    # does not carry this over on its own (MANUAL-STEPS.md §2, caught by the
    # opus review before install day rather than discovered after).
    allowDiscards = true;
  };

  fileSystems."/boot" = {
    device = "/dev/disk/by-uuid/6F7C-CFA4";
    fsType = "vfat";
    options = [ "fmask=0077" "dmask=0077" ];
  };

  # randomEncryption swap has no persistent on-disk signature to detect —
  # by-partlabel rather than by-uuid, same reasoning MANUAL-STEPS.md §2
  # flagged ahead of time.
  swapDevices = [
    { device = "/dev/disk/by-partlabel/disk-main-swap"; randomEncryption.enable = true; }
  ];

  # ── midden (disko.nix: disk.midden) ────────────────────────────────────────
  # /var/log/journal is NOT root, so no boot.initrd.luks.devices entry here —
  # cryptlogs is opened during normal boot by configuration.nix's own
  # environment.etc."crypttab", not initrd (DECISIONS.md §7). By the time
  # this fileSystems entry mounts, /dev/mapper/cryptlogs already exists.
  fileSystems."/var/log/journal" = {
    device = "/dev/mapper/cryptlogs";
    fsType = "ext4";
    options = [ "noatime" ];
  };

  # Plain, unencrypted (reversed 2026-08-31 — see disko.nix's
  # nixBuildScratch comment) — referenced directly by its own filesystem
  # UUID, no LUKS layer to open first.
  fileSystems."/var/cache/nix-build" = {
    device = "/dev/disk/by-uuid/776b9cfd-ccc9-4e5a-bc4c-584289a5d45f";
    fsType = "ext4";
    options = [ "noatime" ];
  };

  nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";
  hardware.cpu.intel.updateMicrocode = lib.mkDefault config.hardware.enableRedistributableFirmware;
}
