# ─────────────────────────────────────────────────────────────────────────────
# Real hardware config, reconciled after the disko.nix install (module list
# from `nixos-generate-config --no-filesystems`, UUIDs from blkid). mpt3sas
# stays even with the HBA's disks disconnected — the controller enumerates on
# the PCIe bus regardless.
#
# ⚠ `/boot` is on the WD Blue ESP (special-vdev disk s-3255, by-uuid
# 0B82-159C), on the onboard C204 — the only controller this board UEFI-boots
# (no NVMe boot driver, and nothing behind the LSI HBA boots either — see
# PLATFORM.md §11 / DECISIONS.md). midden's old ESP (5B33-9B74) is kept as a
# bootable fallback; the NVMe's own ESP stays vestigial.
#
# ⚠ This BIOS boots ONLY the removable-media fallback path
# (`\EFI\BOOT\BOOTX64.EFI`), never `\EFI\systemd\systemd-bootx64.efi`. So the
# working boot entry is a *manually created* efibootmgr entry ("galactica-wdblue",
# HD(1,GPT,d3ede3b6,…)/\EFI\BOOT\BOOTX64.EFI) — a partition-signature path, so it
# survives the disk moving controllers. That is why configuration.nix sets
# `boot.loader.efi.canTouchEfiVariables = false`: NixOS must NOT manage the NVRAM
# entry here, or it re-creates an unbootable `\EFI\systemd\` entry every switch.
# If NVRAM is ever cleared, re-create the entry by hand:
#   efibootmgr --create --disk <WD-Blue-dev> --part 1 \
#     --label galactica-wdblue --loader '\EFI\BOOT\BOOTX64.EFI'
# Root/`/nix`/`/home` remain on the NVMe; only the ESP moved.
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
    # does not carry this over on its own.
    allowDiscards = true;
  };

  # WD Blue ESP — see the header for the manual NVRAM entry this BIOS needs.
  fileSystems."/boot" = {
    device = "/dev/disk/by-uuid/0B82-159C";
    fsType = "vfat";
    options = [ "fmask=0077" "dmask=0077" ];
  };

  # randomEncryption swap has no persistent on-disk signature to detect —
  # hence by-partlabel rather than by-uuid.
  swapDevices = [
    { device = "/dev/disk/by-partlabel/disk-main-swap"; randomEncryption.enable = true; }
  ];

  # ── midden (disko.nix: disk.midden) ────────────────────────────────────────
  # cryptlogs is opened in stage 2 by configuration.nix's crypttab (not
  # initrd, DECISIONS.md §7) — and only when secrets/galactica.yaml exists,
  # so `nofail` is required: without it a secrets-less boot waits out the
  # ~90s device timeout on a mapper device that never appears.
  fileSystems."/var/log/journal" = {
    device = "/dev/mapper/cryptlogs";
    fsType = "ext4";
    options = [ "noatime" "nofail" ];
  };

  # Plain, unencrypted (see disko.nix's nixBuildScratch comment) — no LUKS
  # layer to open first. UUID is post-reformat, newer than the first disko run.
  fileSystems."/var/cache/nix-build" = {
    device = "/dev/disk/by-uuid/644dbaff-563a-415f-877b-11d41ed8cb89";
    fsType = "ext4";
    options = [ "noatime" "nofail" ];
  };

  nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";
  hardware.cpu.intel.updateMicrocode = lib.mkDefault config.hardware.enableRedistributableFirmware;
}
