# ─────────────────────────────────────────────────────────────────────────────
# Reference disko spec for liskov — NOT imported into the system closure.
# ─────────────────────────────────────────────────────────────────────────────
# Documents the INTENDED on-disk layout and can drive a declarative install.
# Deliberately kept out of flake.nix / configuration.nix so it does not
# double-define `fileSystems.*` against hardware-configuration.nix (which
# provides those for eval). Same arrangement as hosts/pegasus/disko.nix.
#
# To use it at install time on the real machine:
#   nix run github:nix-community/disko -- --mode disko ./hosts/liskov/disko.nix
# then `nixos-generate-config --no-filesystems --root /mnt` and reconcile the
# generated hardware-configuration.nix against the checked-in one.
#
# ⚠ THE ONE THING TO GET RIGHT HERE
# liskov installs onto the Kingston 120GB SSD, which must be on an ONBOARD
# SATA port before you run this. It ships cabled to the ASM1064 (port 4), and
# the ASM1064 is bound to vfio-pci and handed to the Unraid guest — so if the
# Kingston is still on it, the host cannot see its own root filesystem. See
# hosts/liskov/DEPLOY.md § Recabling.
#
# disko WIPES whatever `device` points at. Every other drive in this machine is
# a live Unraid array/pool member. Confirm the by-id path resolves to the
# Kingston and nothing else before running:
#   ls -l /dev/disk/by-id/ | grep -i kingston
#   lsblk -o NAME,SIZE,MODEL,SERIAL
{
  disko.devices = {
    disk.main = {
      type = "disk";
      # TODO(install): replace with the real by-id path read off the machine.
      # by-id rather than /dev/sdX — with three SATA controllers and a dozen
      # drives, sdX enumeration order is not stable across boots here.
      device = "/dev/disk/by-id/ata-KINGSTON_REPLACE_WITH_REAL_SERIAL";
      content = {
        type = "gpt";
        partitions = {
          # 1MB BIOS boot partition, unused if the board boots UEFI.
          #
          # Insurance, not indecision: the X9SCM's UEFI support depends on its
          # BIOS revision, and we cannot verify that from here. If the board
          # turns out to be legacy-only — or if you choose to keep it in legacy
          # mode so the Unraid flash drive's boot path is left byte-for-byte
          # untouched (see DEPLOY.md § Bootloader) — GRUB on GPT needs this
          # partition to exist. Creating it costs 1MB now; discovering you need
          # it after install costs a repartition of the root disk.
          biosBoot = {
            priority = 1;
            size = "1M";
            type = "EF02";
          };
          ESP = {
            priority = 2;
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
            priority = 3;
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
                  # libvirt guest state: domain XML, nvram (OVMF varstore), and
                  # anything else /var/lib/libvirt accumulates. Its own subvolume
                  # so the guest definition survives a root rollback, and so
                  # snapshots of @ don't drag OVMF varstores along.
                  "@libvirt" = { mountpoint = "/var/lib/libvirt"; mountOptions = [ "compress=zstd" "noatime" ]; };
                };
              };
            };
          };
        };
      };
    };
  };
}
