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
# Adjust `device` to the real NVMe path (e.g. /dev/nvme0n1) before running.
{
  disko.devices = {
    disk.main = {
      type = "disk";
      device = "/dev/nvme0n1"; # VERIFY on real hardware
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
