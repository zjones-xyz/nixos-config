{ config, pkgs, lib, utils, ... }:

let
  # "mnt-btrfs\x2dpool.mount". Derived rather than written out by hand — the
  # \x2d escaping of the literal dash is exactly the sort of thing that is
  # silently wrong when typed from memory, and a wrong unit name here fails
  # open (no ordering at all) instead of erroring.
  poolMountUnit = "${utils.escapeSystemdPath "/mnt/btrfs-pool"}.mount";
in

# ─────────────────────────────────────────────────────────────────────────────
# Local btrfs snapshots (btrbk)
# ─────────────────────────────────────────────────────────────────────────────
# Fills in the half of the disk layout that was scaffolded but never used: both
# disko.nix and hardware-configuration.nix create and mount an `@snapshots`
# subvolume, and until now nothing ever wrote a snapshot into it.
#
# THIS IS NOT A BACKUP. Every snapshot lives on the same filesystem, on the
# same disk, inside the same LUKS container as the data it snapshots. It buys
# back an `rm -rf`, a bad upgrade of something outside the Nix store, or a
# config change that corrupted mutable state — it buys back nothing at all
# from a dead NVMe or a lost passphrase. Offsite backup is a separate job.
#
# Assumes the fleet's standard `@ @home @nix @snapshots` layout; any host with
# that layout can import this unchanged.
{
  # btrbk wants to see the subvolumes as siblings under the filesystem's top
  # level, not through the mounts that graft them into /, /home, etc. subvolid=5
  # is that top level (btrfs's FS_TREE), so this mount exposes @, @home and
  # @snapshots as plain directories in one place — the layout btrbk's `volume`
  # / `subvolume` config is written against.
  #
  # Device is taken from the root filesystem rather than hardcoded, so this
  # module carries no host-specific paths (on pegasus it resolves to
  # /dev/mapper/cryptroot, i.e. inside the LUKS container, already unlocked by
  # the time any of this runs).
  #
  # `nofail` for the same reason the microvm volumes learned it the hard way in
  # 2026-07: a mount that a *snapshot timer* needs must never be able to hold
  # the whole workstation's boot hostage.
  fileSystems."/mnt/btrfs-pool" = {
    device = config.fileSystems."/".device;
    fsType = "btrfs";
    options = [ "subvolid=5" "noatime" "nofail" ];
  };

  services.btrbk.instances.local = {
    onCalendar = "hourly";

    # Snapshot-only: no `target`, so btrbk never tries to send anywhere. This
    # is what makes the instance purely local — see the not-a-backup note above.
    snapshotOnly = true;

    settings = {
      # Keep everything from the last 2 days regardless of what the retention
      # policy below would otherwise prune, then thin out: hourly for a day,
      # daily for two weeks, weekly for two months. The recent-and-dense end is
      # the one that matters — "I broke something this afternoon" is the case
      # you actually hit.
      snapshot_preserve_min = "2d";
      snapshot_preserve = "24h 14d 8w";

      volume."/mnt/btrfs-pool" = {
        snapshot_dir = "@snapshots";

        # @nix is deliberately absent: the Nix store is already rebuildable
        # from the flake and rollback there is `nixos-rebuild --rollback` /
        # picking an older boot generation, so snapshotting it would burn space
        # duplicating the one directory that least needs it. @games is absent
        # for the opposite reason — enormous, churny, and re-downloadable.
        subvolume = {
          "@" = { };
          "@home" = { };
        };
      };
    };
  };

  # The pool mount is `nofail`, so nothing else guarantees it is up before the
  # hourly timer fires — and btrbk against a missing /mnt/btrfs-pool/@ is a
  # failed unit, not a no-op. Bind the ordering explicitly.
  systemd.services.btrbk-local = {
    after = [ poolMountUnit ];
    requires = [ poolMountUnit ];
  };
}
