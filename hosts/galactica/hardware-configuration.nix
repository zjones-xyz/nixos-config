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
#
# ⚠ `/boot` is on midden (by-uuid/5B33-9B74), and stays there for now. The
# NVMe can't be a UEFI boot target on this board (PLATFORM.md §11, resolved
# negative — the BIOS only ever listed the USB stick). MANUAL-STEPS.md §9
# planned to migrate the ESP onto a special-vdev SSD, and it was attempted on
# 2026-09-01 (MX100 first — it hard-failed on first write; then the WD Blue),
# but BOTH remaining special-vdev SSDs turned out to sit on the add-in ASMedia
# SATA controller (PCI 02:00.0), which this BIOS cannot UEFI-boot. Only the
# onboard C204 (00:1f.2 — midden + the four spinners) is bootable. So the ESP
# stays on midden until the WD Blue is physically recabled to the free onboard
# C204 port (the port it occupied before the array-build recabling). The WD
# Blue's 1 GiB ESP partition (by-uuid 0B82-159C) still exists with a
# bootloader installed — now vestigial, like the NVMe's, and reused when the
# recabling happens. See the /boot fileSystems entry below + the project memory.
# ⚠ midden is the disk this design expects to fail within ~a year, so this is
# a known, accepted temporary risk — not the intended end state.
# Root/`/nix`/`/home` remain on the NVMe.
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

  # On midden — see the header note. The WD Blue ESP migration was reverted
  # 2026-09-01 (WD Blue is on the non-bootable add-in ASMedia controller);
  # ESP stays here until the WD Blue is recabled to the onboard C204.
  fileSystems."/boot" = {
    device = "/dev/disk/by-uuid/5B33-9B74";
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
  # this fileSystems entry mounts, /dev/mapper/cryptlogs already exists —
  # PROVIDED secrets/galactica.yaml exists, since that crypttab entry is
  # gated on `hasSops`. Found live, the hard way, on the first real boot:
  # without `nofail` here, a boot with no secrets file yet (this one) waits
  # out systemd's default ~90s device timeout for a mapper device that will
  # never appear, before continuing in a degraded boot. `nofail` matches
  # what MANUAL-STEPS.md §2 already called for and this file should have had
  # from the start.
  fileSystems."/var/log/journal" = {
    device = "/dev/mapper/cryptlogs";
    fsType = "ext4";
    options = [ "noatime" "nofail" ];
  };

  # Plain, unencrypted (reversed 2026-08-31 — see disko.nix's
  # nixBuildScratch comment) — referenced directly by its own filesystem
  # UUID, no LUKS layer to open first. UUID is post-reformat: this partition
  # was deleted and recreated 1G smaller to make room for /boot above, so
  # its original UUID from the first disko run no longer applies.
  fileSystems."/var/cache/nix-build" = {
    device = "/dev/disk/by-uuid/644dbaff-563a-415f-877b-11d41ed8cb89";
    fsType = "ext4";
    options = [ "noatime" "nofail" ];
  };

  nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";
  hardware.cpu.intel.updateMicrocode = lib.mkDefault config.hardware.enableRedistributableFirmware;
}
