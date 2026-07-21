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

  # ── NTFS data drives (internal SATA, leftover from the pre-NixOS setup) ───
  # Referenced by /dev/disk/by-id (stable across SATA port/enumeration
  # changes) rather than /dev/sdX, same convention as disko.nix's NVMe note.
  # fsType "ntfs3" is the in-kernel driver (mainlined since Linux 5.15, built
  # as a loadable module by this kernel package — no boot.kernelModules entry
  # needed, it autoloads on mount) rather than "ntfs"/"ntfs-3g", which would
  # dispatch to the userspace FUSE driver instead; confirmed via the pinned
  # nixpkgs source that plain fsType = "ntfs" prefers ntfs-3g even with the
  # kernel driver available. `uid`/`gid` are z's actual live values (`id z`
  # on pegasus — not pinned anywhere in this repo's user config, so these are
  # literal, not derived from config.users.users.z, which has no static uid
  # here). `nofail` so a disconnected/failed drive degrades to "not mounted"
  # rather than blocking the whole host's boot (see the microvm volumes
  # above for the exact same lesson, learned the hard way).
  #
  # All three start read-only: reading is the priority (per request), and
  # read-write on NTFS carries a real corruption risk if the volume was ever
  # left mid-hibernation by Windows (Fast Startup) rather than cleanly shut
  # down. Confirmed clean via `ntfsfix --no-action` (ntfs-3g's dry-run check,
  # writes nothing) for the Samsung SSD specifically (2026-07-21) before
  # including it here at all — Spinner/Toshiba haven't had the same check run
  # against them yet. Flipping any of these to read-write later is just
  # dropping "ro" from its options list — worth running the same check first.
  fileSystems."/mnt/spinner" = {
    device = "/dev/disk/by-id/ata-WDC_WD10EZEX-08WN4A0_WD-WCC6Y5LKP2NJ-part2";
    fsType = "ntfs3";
    options = [ "ro" "nofail" "uid=1000" "gid=100" "windows_names" ];
  };

  fileSystems."/mnt/toshiba" = {
    device = "/dev/disk/by-id/ata-TOSHIBA_DT01ACA300_76HE4XDAS-part2";
    fsType = "ntfs3";
    options = [ "ro" "nofail" "uid=1000" "gid=100" "windows_names" ];
  };

  # Samsung SSD's actual Windows C: partition (sda3 — sda1/sda2 are the EFI
  # System Partition and Microsoft Reserved Partition, sda4 is almost
  # certainly the WinRE recovery partition and isn't mounted here; nothing
  # about it was checked before excluding it, so revisit if it turns out to
  # be wanted too). This is the one partition here that's part of an actual
  # bootable Windows install rather than a plain data drive, hence the
  # ntfsfix check specifically before adding it.
  fileSystems."/mnt/windows" = {
    device = "/dev/disk/by-id/ata-Samsung_SSD_860_QVO_1TB_S59HNG0N417636E-part3";
    fsType = "ntfs3";
    options = [ "ro" "nofail" "uid=1000" "gid=100" "windows_names" ];
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
