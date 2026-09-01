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
#
# ⚠ **The NVMe does NOT actually boot on this firmware — do not put an ESP
# here on a future re-install.** Discovered live, 2026-08-31: this 2011-era
# board's UEFI genuinely works (confirmed via a successful `UEFI: USB` boot)
# but has no NVMe boot driver — the boot-option filesystem browser never
# listed the NVMe as a candidate across multiple attempts, only the USB
# stick. `PLATFORM.md` §11 had flagged this as an open question; it's now
# answered, negatively. The ESP partition below is kept in this spec only
# because removing it from an already-partitioned live disk wasn't worth
# the disruption — it is NOT where `/boot` actually lives. See disk.midden's
# ESP partition further down for where it really goes, and
# hardware-configuration.nix's header for the full story.
{
  disko.devices = {
    disk.main = {
      type = "disk";
      device = "/dev/disk/by-id/nvme-SPCC_M.2_PCIe_SSD_AA2300905N401KG00206";
      content = {
        type = "gpt";
        partitions = {
          # Vestigial — NOT the real /boot (see the header warning above).
          # No mountpoint: this partition exists, is formatted, and is
          # simply unused. Kept rather than removed from a live disk that
          # wasn't worth the disruption to change; a genuinely fresh install
          # following this spec from scratch could just drop this partition
          # entirely and give the space to the LUKS container instead.
          ESP = {
            size = "1G";
            type = "EF00";
            content = {
              type = "filesystem";
              format = "vfat";
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
    # already in the machine. Split two ways: /var/log/journal (LUKS'd —
    # logs routinely end up with incidentally-sensitive content), and Nix's
    # build scratch space (`nix.settings.build-dir`, configuration.nix —
    # plain, unencrypted; see that partition's own comment for why the two
    # don't actually share a rationale despite both being disposable). Both
    # deliberately kept off the NVMe root disk to spare it the churn.
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
          # No LUKS here, deliberately — reversed 2026-08-31 (owner's
          # challenge, after the fact: disko had already formatted this one
          # encrypted, fixed while still empty rather than left as-is). The
          # "encrypt everything disposable" reasoning that justifies the
          # logs partition doesn't actually transfer here: logs routinely
          # end up with incidentally-sensitive content (IPs, tokens in error
          # text, paths), but this is purely Nix's own sandboxed build
          # output — derived from nixpkgs/flake inputs that are either
          # public or already unencrypted-readable in the Nix store itself
          # (the store is not confidential by design). Nothing secret should
          # transit here under correct Nix usage; if it did, that's a Nix
          # hygiene bug this encryption layer was never positioned to catch.
          # Plain ext4, same reasoning as /var/log/journal above for the
          # filesystem choice itself (disposable, recreated every build, no
          # btrfs feature actually applies).
          # Shrunk by 1G (2026-08-31, live, after the original disko run —
          # was "100%") to make room for the ESP partition below, once the
          # NVMe proved unbootable. Deleted and recreated rather than
          # resized in place — it was still completely empty, so a fresh
          # mkfs cost nothing.
          nixBuildScratch = {
            size = "-1G";
            content = {
              type = "filesystem";
              format = "ext4";
              mountpoint = "/var/cache/nix-build";
              mountOptions = [ "noatime" ];
            };
          };

          # The REAL /boot — added live, 2026-08-31, after discovering the
          # NVMe's own ESP (disk.main) is unusable on this firmware (see the
          # warning at the top of this file). Deliberately temporary: midden
          # is the one disk in this design explicitly expected to fail
          # within about a year (that's the entire premise behind giving it
          # only disposable data), so tying the machine's ability to boot at
          # all to it is a worse outcome than what midden's failure was
          # originally supposed to cost. Plan (MANUAL-STEPS.md §9): migrate
          # this to MX100 (the largest of the four special-vdev candidate
          # disks) once those are reconnected for the array build — MX100
          # has room for both a 1G ESP and its eventual 420G special-vdev
          # partition, so this doesn't need to be undone later, just moved.
          # Not on the special-vdev disks from the start only because they
          # weren't reconnected yet at this point in the install.
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
