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
  # All start read-only: reading is the priority (per request), and
  # read-write on NTFS carries a real corruption risk if the volume was ever
  # left mid-hibernation by Windows (Fast Startup) rather than cleanly shut
  # down. Checked clean via `ntfsfix --no-action` (ntfs-3g's dry-run check,
  # writes nothing) for all three NTFS drives before mounting them
  # (2026-07-21) — Samsung SSD first (before being included at all, since it's
  # the one with an actual bootable Windows install), Spinner and the old
  # Toshiba NTFS partition afterward on request, purely to confirm neither was
  # in a vulnerable state. Flipping to read-write later is just dropping "ro"
  # from a mount's options list — worth re-running the same check first, since
  # it's a point-in-time result, not a standing guarantee.
  fileSystems."/mnt/spinner" = {
    device = "/dev/disk/by-id/ata-WDC_WD10EZEX-08WN4A0_WD-WCC6Y5LKP2NJ-part2";
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

  # The Toshiba drive's original single NTFS partition was confirmed empty
  # (2026-07-21, on request) and repartitioned: a GPT with a btrfs partition
  # (the remainder, ~2.34TiB) and a fixed 400GiB exFAT partition, both
  # formatted via sgdisk/mkfs.btrfs/mkfs.exfat directly on the real hardware
  # (an imperative, one-time, destructive step — not something
  # `nixos-rebuild switch` does; see DECISIONS.md for the full account,
  # including why `parted`'s CLI was abandoned mid-attempt in favor of
  # `sgdisk`). `-part1`/`-part2` now refer to the NEW partitions in this
  # layout, not the old single-NTFS-partition one.
  #
  # btrfs mountpoint read-write (not "ro" like the NTFS mounts above — no
  # Windows-hibernation-style corruption risk on a filesystem this repo
  # itself just created). Its top-level directory defaults to root:root 0755
  # straight out of mkfs — same class of bug as @games and the microvm
  # volumes — fixed below via systemd.tmpfiles.rules instead of relying on
  # NTFS-style uid=/gid= mount options, which btrfs doesn't have (real Unix
  # permissions instead).
  fileSystems."/mnt/toshiba" = {
    device = "/dev/disk/by-id/ata-TOSHIBA_DT01ACA300_76HE4XDAS-part1";
    fsType = "btrfs";
    options = [ "compress=zstd" "noatime" "nofail" ];
  };

  # exFAT: mainlined in-kernel driver (since Linux 5.7) handles mount/read/
  # write directly, same story as ntfs3 — only mkfs/fsck need the userspace
  # exfatprogs package (added to environment.systemPackages in
  # configuration.nix). uid=/gid=/umask= needed here since, like NTFS, exFAT
  # has no on-disk owner metadata of its own.
  fileSystems."/mnt/toshiba-exfat" = {
    device = "/dev/disk/by-id/ata-TOSHIBA_DT01ACA300_76HE4XDAS-part2";
    fsType = "exfat";
    options = [ "nofail" "uid=1000" "gid=100" "umask=022" ];
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
