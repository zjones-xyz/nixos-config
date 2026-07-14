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
# pegasus is single-NVMe: the CachyOS drive was physically removed before
# install (2026-07-11), so NixOS owns the one remaining NVMe outright — no
# dual-boot, no "which drive is blank" ambiguity. Still identify it by
# /dev/disk/by-id/ rather than /dev/nvmeXn1 (index can still shift if other
# NVMes are ever added later):
#   ls -l /dev/disk/by-id/ | grep nvme
# then set `device` below to the matching /dev/disk/by-id/nvme-<model>_<serial>
# path. disko will wipe whatever `device` points at, so don't run this against
# a drive with anything else on it (e.g. one of the SATA/USB Windows drives).
{
  disko.devices = {
    disk.main = {
      type = "disk";
      # PNY CS3250 2TB, confirmed via `ls -l /dev/disk/by-id/ | grep -i nvme` (2026-07-11).
      device = "/dev/disk/by-id/nvme-PNY_CS3250_2TB_SSD_PNY25372509080100257";
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
