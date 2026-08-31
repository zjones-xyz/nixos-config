# ─────────────────────────────────────────────────────────────────────────────
# Reference disko spec for galactica's root NVMe — NOT imported into the system
# closure. Same reasoning as hosts/pegasus/disko.nix: kept out of
# flake.nix/configuration.nix so it doesn't double-define `fileSystems.*`
# against hardware-configuration.nix (generated separately, at install time).
# ─────────────────────────────────────────────────────────────────────────────
#
# To use it at install time on the real machine (booted from the ISO, both
# HBA SFF-8087 cables physically disconnected first — sidepool on one, the
# three SATA SSD pools on the other — so disko cannot touch either even by
# mistake):
#   ls -l /dev/disk/by-id/ | grep nvme
#   nix run github:nix-community/disko -- --mode disko ./hosts/galactica/disko.nix
# then `nixos-generate-config --no-filesystems --root /mnt` and reconcile.
#
# ✅ `device` confirmed 2026-08-31 directly on Tower (`ls -l /dev/disk/by-id/`):
# `nvme-SPCC_M.2_PCIe_SSD_AA2300905N401KG00206` — matching the separate
# session's live-boot serial, NOT HARDWARE-MAP.md's `m2-140B` entry
# (`23049339-090140B`), confirming that was a package-label-vs-controller
# mismatch rather than a different drive (DRAM-less Silicon Motion SM2269XT
# under Silicon Power/SPCC branding). Still double-check nothing's shifted
# before running disko — it wipes whatever `device` points at.
#
# Root stays LUKS + btrfs, matching the fleet's LUKS-underneath convention
# (galactica/DECISIONS.md §7) rather than ZFS — the RAIDZ1 array is where ZFS
# lives on this host, built separately, after this install.
{
  disko.devices = {
    disk.main = {
      type = "disk";
      device = "/dev/disk/by-id/nvme-SPCC_M.2_PCIe_SSD_AA2300905N401KG00206";
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
          # Low-swappiness swap partition — a real partition, created before
          # any filesystem, never a swap file on top of btrfs/ZFS.
          # vm.swappiness is set low in configuration.nix; this is a pressure
          # release valve, not a primary memory-extension tier, on a box with
          # 32 GB RAM and a mostly-sequential media workload.
          #
          # Sized generously (32G, matching RAM) on purpose: shrinking a
          # partition later means an in-place resize or a rebuild, but
          # growing one is nearly the same amount of work either way — so the
          # cheap direction to be wrong in is oversized. Revisit once there's
          # operational experience showing 32G was never needed.
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
                # Deliberately NO @appdata subvolume here, reversing the
                # migration handoff's original "NVMe: appdata, Docker
                # volumes, swap" plan. Decided 2026-08-31: appdata (Docker's
                # bind-mounted config/database directories — the actual
                # application state, not Docker's own engine storage, which
                # DOES stay here under the default /var/lib/docker) moves to
                # a ZFS dataset on the RAIDZ1 pool once it exists, with
                # `special_small_blocks` set so it lands on the special
                # vdev's mirrored SSDs instead of the spinners — real
                # redundancy for the host's most irreplaceable mutable
                # state, which a single unmirrored NVMe subvolume never gave
                # it. See MANUAL-STEPS.md §9/§10. Consequence, accepted
                # knowingly: Docker/appdata-dependent services can't start
                # until the array (special vdev included) is fully built —
                # no interim NVMe home, on purpose.
              };
            };
          };
        };
      };
    };

    # `s-9545` (~223.6GB SATA SSD, HARDWARE-MAP.md) — Unraid's `fastservices`
    # pool, name retired here since that role no longer applies: its pool
    # data already migrated off to sidepool, freeing it to repurpose.
    # Nicknamed `midden` (2026-08-31, owner's choice over `scratch`) —
    # disposable-but-useful accumulation being the whole point of a midden,
    # same idea as everything landing on it. Formal inventory ID stays
    # `s-9545` per DISK-LABELLING.md's convention of keeping roles/nicknames
    # off the printed identifier, same pattern as `h-P2NJ`/"spinner" on
    # pegasus. Replaces the earlier Kingston (`s-5509`) plan — that disk is
    # currently out of the case, while this one's already known-good and
    # already in the machine. Split two ways: /var/log/journal, and Nix's
    # build scratch space (`nix.settings.build-dir`, configuration.nix) —
    # both deliberately kept off the NVMe root disk to spare it the churn,
    # both disposable enough that losing the disk costs nothing worth
    # protecting beyond confidentiality. LUKS'd anyway, matching the fleet
    # convention of encrypting everything regardless of how disposable the
    # contents are — same reasoning as the special vdev pairs.
    #
    # ✅ `device` confirmed 2026-08-31 directly on Tower: `ata-SATA_SSD_19013024009545`.
    # Already carries an Unraid partition (`-part1`) — disko wipes it regardless.
    #
    # Split 48G/175G rather than evenly — logs are already generously sized
    # relative to actual need (same reasoning as the swap partition), while
    # build scratch space benefits more from headroom (a large package or
    # kernel build can transiently need tens of GB). Adjust freely; neither
    # number is load-bearing.
    disk.midden = {
      type = "disk";
      device = "/dev/disk/by-id/ata-SATA_SSD_19013024009545";
      content = {
        type = "gpt";
        partitions = {
          logs = {
            size = "48G";
            content = {
              type = "luks";
              name = "cryptlogs";
              settings.allowDiscards = true;
              content = {
                # ext4, not btrfs. journald actually already sets FS_NOCOW_FL
                # on its own journal directory when it IS on btrfs, so the
                # CoW-overhead argument doesn't hold — an opus review agent
                # caught that this file's original reasoning here was wrong
                # on that specific point. ext4 is kept anyway on simplicity
                # grounds: this disk is excluded from btrbk's snapshot pool
                # regardless (that module only walks root's own device), so
                # there's still nothing btrfs would buy here, even though
                # "avoids CoW overhead" wasn't a real reason. Honest tradeoff
                # going the other way: on a disk explicitly expected to fail
                # within about a year, btrfs would at least detect bitrot
                # before it's found the hard way — accepted, since the data
                # is disposable by design.
                #
                # Mounted at /var/log/journal specifically, NOT /var/log —
                # NixOS hardcodes /var/log itself into pathsNeededForBoot
                # (nixos/lib/utils.nix), which forces `x-initrd.mount` onto
                # its fstab entry even though this device can only unlock in
                # stage 2 (crypttab), and `nofail` alone doesn't fix it: it
                # only stops the boot hang, and unblocks the mount ordering
                # enough that it can land *after*
                # systemd-journal-flush.service already flushed into root's
                # /var/log — silently shadowing the persistent journal right
                # back onto the NVMe. /var/log/journal isn't in that
                # hardcoded list, needs no x-initrd.mount, and is the entire
                # actual workload anyway (journald + Docker's journald log
                # driver). Confirmed by rendering the actual generated fstab
                # entry during review.
                type = "filesystem";
                format = "ext4";
                mountpoint = "/var/log/journal";
                mountOptions = [ "noatime" ];
              };
            };
          };
          nixBuildScratch = {
            size = "100%";
            content = {
              type = "luks";
              name = "cryptnixbuild";
              settings.allowDiscards = true;
              content = {
                # Same ext4 reasoning as /var/log above — this is scratch
                # space Nix recreates on every build, not data worth any of
                # btrfs's CoW/snapshot machinery.
                type = "filesystem";
                format = "ext4";
                mountpoint = "/var/cache/nix-build";
                mountOptions = [ "noatime" ];
              };
            };
          };
        };
      };
    };
  };
}
