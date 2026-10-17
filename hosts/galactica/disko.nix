# ─────────────────────────────────────────────────────────────────────────────
# Reference disko spec for galactica's root NVMe — NOT imported into the system
# closure (same reasoning as hosts/pegasus/disko.nix: avoids double-defining
# `fileSystems.*` against the generated hardware-configuration.nix).
#
# Install-time use (ISO booted, BOTH HBA SFF-8087 cables disconnected first so
# disko cannot touch the array disks even by mistake):
#   ls -l /dev/disk/by-id/ | grep nvme   # re-verify device before wiping
#   nix run github:nix-community/disko -- --mode disko ./hosts/galactica/disko.nix
# then `nixos-generate-config --no-filesystems --root /mnt` and reconcile.
#
# ⚠ The NVMe does NOT boot on this firmware (no NVMe UEFI driver) — do not put
# the real ESP here on a re-install. /boot actually lives on the WD Blue
# special-vdev disk; see hardware-configuration.nix's header and DECISIONS.md.
{
  disko.devices = {
    disk.main = {
      type = "disk";
      device = "/dev/disk/by-id/nvme-SPCC_M.2_PCIe_SSD_AA2300905N401KG00206";
      content = {
        type = "gpt";
        partitions = {
          # Vestigial — formatted but unused, NOT the real /boot (see header).
          # A fresh install could drop it and give the space to LUKS.
          ESP = {
            size = "1G";
            type = "EF00";
            content = {
              type = "filesystem";
              format = "vfat";
              mountOptions = [ "fmask=0077" "dmask=0077" ];
            };
          };
          # Pressure-release valve, not a memory tier (vm.swappiness is set
          # low in configuration.nix). Oversized on purpose — shrinking later
          # is the expensive direction to be wrong in.
          swap = {
            size = "32G";
            content = {
              type = "swap";
              randomEncryption = true;
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
                };
                # Deliberately NO @appdata subvolume: appdata lives on the
                # RAIDZ1 pool (special_small_blocks → mirrored SSDs) for real
                # redundancy — see MANUAL-STEPS.md §9/§10. Docker's own engine
                # storage stays here under the default /var/lib/docker.
              };
            };
          };
        };
      };
    };

    # `s-9545` ("midden", ~223.6GB SATA SSD — HARDWARE-MAP.md): disposable
    # churn kept off the NVMe root disk. Split 48G logs / rest build-scratch;
    # neither number is load-bearing.
    disk.midden = {
      type = "disk";
      device = "/dev/disk/by-id/ata-SATA_SSD_19013024009545";
      content = {
        type = "gpt";
        partitions = {
          # LUKS'd: logs routinely pick up incidentally-sensitive content.
          logs = {
            size = "48G";
            content = {
              type = "luks";
              name = "cryptlogs";
              settings.allowDiscards = true;
              content = {
                # Mounted at /var/log/journal specifically, NOT /var/log —
                # NixOS hardcodes /var/log into pathsNeededForBoot
                # (nixos/lib/utils.nix), forcing `x-initrd.mount` onto its
                # fstab entry even though this device only unlocks in stage 2
                # (crypttab). `nofail` alone doesn't fix it: the mount can
                # then land *after* systemd-journal-flush already flushed into
                # root's /var/log, silently shadowing the persistent journal
                # back onto the NVMe. /var/log/journal isn't in that list and
                # is the entire actual workload anyway.
                type = "filesystem";
                format = "ext4";
                mountpoint = "/var/log/journal";
                mountOptions = [ "noatime" ];
              };
            };
          };
          # No LUKS, deliberately: purely Nix's own sandboxed build output,
          # derived from inputs already world-readable in the store — the
          # logs partition's "incidentally sensitive" reasoning doesn't
          # transfer. ext4 for the same reason as above (disposable, no
          # btrfs feature applies).
          nixBuildScratch = {
            size = "-1G";
            content = {
              type = "filesystem";
              format = "ext4";
              mountpoint = "/var/cache/nix-build";
              mountOptions = [ "noatime" ];
            };
          };

          # FALLBACK /boot — carries a real systemd-boot install and NVRAM
          # entry, but the live /boot has since moved to a 1G ESP on the WD
          # Blue special-vdev disk (carved imperatively, not via this spec) —
          # see hardware-configuration.nix's header. Kept as a known-bootable
          # fallback; disko.nix isn't re-run against the live host.
          ESP = {
            size = "100%";
            type = "EF00";
            content = {
              type = "filesystem";
              format = "vfat";
              mountpoint = "/boot";
              mountOptions = [ "fmask=0077" "dmask=0077" ];
            };
          };
        };
      };
    };
  };
}
