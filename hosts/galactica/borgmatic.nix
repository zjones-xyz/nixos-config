{ config, pkgs, lib, ... }:

# ── borgmatic → offsite (BorgBase), ZFS-snapshot, property-driven selection ───
#
# galactica's offsite backup of the Critical + Precious tiers (docs/BACKUP.md,
# hosts/galactica/BACKUP-BORG.md). Live since 2026-09-03: the BorgBase repo,
# both sops secrets, and the dataset tags all exist, and the first archive
# verified clean.
#
# ⭐ WHY property-driven, and how borgmatic actually selects datasets.
# borgmatic's ZFS hook (verified against the packaged borgmatic 2.1.5 source,
# borgmatic/hooks/data_source/zfs.py) snapshots a dataset if EITHER:
#   1. the dataset carries the user property `org.torsion.borgmatic:backup`
#      with the exact value `auto` — the hook injects the dataset's mountpoint
#      as a root pattern itself, so it is backed up whether or not it appears
#      in `source_directories`; or
#   2. a configured `source_directories`/`patterns` path falls within the
#      dataset's mountpoint.
# Datasets with `canmount=off` are skipped (their snapshot mounts are empty).
# borgmatic creates each snapshot, mounts it read-only in its runtime dir, backs
# up the frozen copy, then destroys the snapshot — no external snapshot tooling.
#
# We take path (1): `source_directories = [ ]`, and the offsite boundary lives
# on the datasets as a ZFS property (tagged: tank/documents + tank/photos, which
# inherits to the immich children). That keeps selection where the tier lives —
# on the pool — and survives dataset renames. borgmatic keys off its OWN
# property name, not our semantic `homelab:tier`, so the two cannot be collapsed
# into one key; the reconciliation is one `zfs set` per Critical/Precious leaf,
# documented in BACKUP-BORG.md, along with the deferred hot/cold retention split
# this single uniform config accepts.

let
  # Repo label and archive prefix are one string on purpose. archive_name_format
  # is what scopes a `prune --dry-run` run from the admin machine to the right
  # archives — docs/BACKUP.md's highest-consequence shared-repo footgun — so it
  # must not be able to drift from the label it is named for.
  repoLabel = "galactica-offsite";
in
{
  services.borgmatic = {
    enable = true;

    configurations.offsite = {
      # Empty: selection is entirely property-driven (see the header). Every
      # dataset tagged `org.torsion.borgmatic:backup=auto` is discovered and
      # snapshotted automatically; nothing here needs a mountpoint list.
      source_directories = [ ];

      # ── ZFS snapshot hook ──────────────────────────────────────────────────
      # Enabled by the presence of this block. The three commands are pinned
      # to absolute store paths rather than trusting $PATH: the borgmatic
      # systemd unit runs with a restricted path (the NixOS module only adds
      # coreutils), so a bare `zfs`/`mount` would not resolve. `zfs` is taken
      # from `boot.zfs.package` so it matches the kernel module version the
      # pool was imported with, not a possibly-divergent `pkgs.zfs`.
      zfs = {
        zfs_command = "${config.boot.zfs.package}/bin/zfs";
        mount_command = "${pkgs.util-linux}/bin/mount";
        umount_command = "${pkgs.util-linux}/bin/umount";
      };

      repositories = [
        { path = "ssh://kentmevx@kentmevx.repo.borgbase.com/./repo"; label = repoLabel; }
      ];

      archive_name_format = "${repoLabel}-{now:%Y-%m-%dT%H:%M:%S.%f}";

      # Passphrase and key via sops (declared below). `cat` is bare because
      # the NixOS borgmatic module already puts coreutils on the unit's path.
      encryption_passcommand = "cat ${config.sops.secrets."borgmatic/passphrase".path}";
      ssh_command = "ssh -i ${config.sops.secrets."borgmatic/ssh_key".path} -o UserKnownHostsFile=/var/lib/borgmatic/ssh/known_hosts -o StrictHostKeyChecking=yes";

      # Let borg compress; the ZFS datasets in scope are plain file trees, so
      # none of docs/BACKUP.md §4d's pre-compression database footgun applies.
      compression = "zstd";
      exclude_caches = true;
      exclude_if_present = [ ".nobackup" ];

      # Skip `compact`, NOT `prune`. Under an append-only key prune succeeds —
      # it only marks archives deleted in the manifest — so the keep_* policy
      # below is enforced here nightly. `compact` is the silent no-op, because
      # reclaiming segment space is a real delete; BorgBase exposes that as a
      # manual "More > Compact repo" action. Same call as pegasus's borgmatic.
      skip_actions = [ "compact" ];

      # ⟨Proposal, not decided — a single uniform policy for the mixed
      # Critical (documents: small, high-churn, wants depth) + Precious
      # (photos: large, near-immutable) set. The hot/cold split that would
      # tune these per-tier needs two explicitly-scoped configs and is
      # deferred — see BACKUP-BORG.md.⟩ Enforced nightly, so these also bound the
      # archive count (~30) that the checks below walk.
      keep_daily = 7;
      keep_weekly = 8;
      keep_monthly = 12;
      keep_yearly = 3;

      checks = [
        { name = "repository"; frequency = "2 weeks"; }
        { name = "archives"; frequency = "1 month"; }
      ];

      # Failure/heartbeat monitoring is deferred to BorgBase's own inactivity
      # alerting (docs/BACKUP.md §6), the fleet-wide decision — same stance as
      # hosts/pegasus/borgmatic.nix, which also carries no ntfy/uptime_kuma
      # hook. BorgBase's alert is a config-free toggle in its UI and, unlike a
      # push from this host, does not depend on any fleet service being up.
    };
  };

  # ── sops secrets this config references ────────────────────────────────────
  # The ssh key is materialised at a fixed path so `known_hosts` can sit beside
  # it under /var/lib/borgmatic/ssh.
  sops.secrets."borgmatic/passphrase" = { };
  sops.secrets."borgmatic/ssh_key" = {
    path = "/var/lib/borgmatic/ssh/id_ed25519";
    mode = "0400";
  };

  # ── systemd unit overrides — REQUIRED for the ZFS hook to work at runtime ──
  # Verified against the packaged unit (borgmatic 2.1.5,
  # lib/systemd/system/borgmatic.service); its own inline comments call out
  # (2) and (3) as the filesystem-hook footguns. Without these the unit either
  # refuses to start or the snapshot/mount silently fails:
  #
  #   1. LoadCredentialEncrypted=borgmatic.pw ships in the unit as its default
  #      secret path (systemd-creds/TPM). This fleet uses sops, not
  #      systemd-creds; systemd refuses to start a unit whose
  #      LoadCredentialEncrypted target is absent. A single empty-string list
  #      element renders the bare `LoadCredentialEncrypted=` line systemd
  #      treats as "reset" (drop-ins accumulate list directives, so mkForce []
  #      would render nothing and leave the upstream line in force — the
  #      empty string is load-bearing). Same fix as pegasus's borgmatic.nix.
  #
  #   2. PrivateDevices=yes hides /dev/zfs — the unit comment: "Filesystem
  #      hooks like ZFS and LVM may not work unless PrivateDevices is
  #      disabled." zfs(8) cannot talk to the kernel without it.
  #
  #   3. CapabilityBoundingSet ships as `CAP_DAC_READ_SEARCH CAP_NET_RAW`,
  #      with NO CAP_SYS_ADMIN — but `zfs snapshot` and mounting the snapshot
  #      both need it (the unit comment suggests exactly "add CAP_SYS_ADMIN").
  #      Drop-in list directives union, so naming CAP_SYS_ADMIN alongside the
  #      upstream two keeps all three. @mount is already in the unit's
  #      SystemCallFilter, and the zfs module is preloaded at boot
  #      (boot.supportedFilesystems / extraPools), so ProtectKernelModules=yes
  #      needs no change.
  #
  # The package unit's Nice=19 / CPUSchedulingPolicy=batch / IOSchedulingClass
  # tuning is deliberately left intact — right for a box that also serves media.
  # 01:30 nightly instead of the packaged unit's midnight. OnCalendar is a
  # systemd LIST directive, so a drop-in ADDS to the packaged value rather than
  # replacing it — the leading "" resets it first, or the timer fires twice.
  # Same reset mechanic as LoadCredentialEncrypted below. RandomizedDelaySec=10m
  # and Persistent=true are left to the package.
  systemd.timers.borgmatic.timerConfig.OnCalendar = [ "" "01:30" ];

  systemd.services.borgmatic.serviceConfig = {
    LoadCredentialEncrypted = lib.mkForce [ "" ];
    PrivateDevices = lib.mkForce false;
    CapabilityBoundingSet = [ "CAP_DAC_READ_SEARCH" "CAP_NET_RAW" "CAP_SYS_ADMIN" ];
  };
}
