# ─────────────────────────────────────────────────────────────────────────────
# Reference disko spec for pegasus — NOT imported into the system closure.
# ─────────────────────────────────────────────────────────────────────────────
# This documents the INTENDED on-disk layout and can drive a declarative
# install. It is deliberately kept out of flake.nix / configuration.nix so it
# does not double-define `fileSystems.*` against hardware-configuration.nix
# (which provides those for eval). See hosts/pegasus/DECISIONS.md.
#
# To use it at install time on the real machine:
#   nix run github:nix-community/disko -- --mode disko ./hosts/pegasus/disko.nix
# then `nixos-generate-config --no-filesystems --root /mnt` and reconcile.
#
# pegasus is dual-NVMe during bring-up: CachyOS stays on its existing drive,
# NixOS installs to a second, blank NVMe added specifically for this. With two
# NVMes in the box, `/dev/nvme0n1` vs `/dev/nvme1n1` is NOT reliably "old drive"
# vs "new drive" — it depends on PCIe slot/boot order, and disko will happily
# wipe whatever `device` points at. Before running, identify the blank drive by
# serial, not by ambiguous index:
#   ls -l /dev/disk/by-id/ | grep nvme
# then set `device` below to the matching /dev/disk/by-id/nvme-<model>_<serial>
# path for the NEW drive. Do not point this at the drive CachyOS is on.
{
  disko.devices = {
    disk.main = {
      type = "disk";
      device = "/dev/disk/by-id/CHANGEME-verify-the-new-drives-serial"; # REQUIRED: set before running
      content = {
        type = "gpt";
        partitions = {
          ESP = {
            size = "1G";
            type = "EF00";
            content = {
              type = "filesystem";
              format = "vfat";
              mountpoint = "/boot";
              mountOptions = [ "fmask=0077" "dmask=0077" ];
            };
          };
          luks = {
            size = "100%";
            content = {
              type = "luks";
              name = "cryptroot";
              settings.allowDiscards = true;
              content = {
                type = "btrfs";
                extraArgs = [ "-f" ];
                subvolumes = {
                  "@" = { mountpoint = "/"; mountOptions = [ "compress=zstd" "noatime" ]; };
                  "@home" = { mountpoint = "/home"; mountOptions = [ "compress=zstd" "noatime" ]; };
                  "@nix" = { mountpoint = "/nix"; mountOptions = [ "compress=zstd" "noatime" ]; };
                  "@snapshots" = { mountpoint = "/.snapshots"; mountOptions = [ "compress=zstd" "noatime" ]; };
                  # Steam library — preserved across reinstalls.
                  "@games" = { mountpoint = "/games"; mountOptions = [ "compress=zstd" "noatime" ]; };
                };
              };
            };
          };
        };
      };
    };
  };
}
