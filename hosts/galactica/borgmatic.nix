{ config, pkgs, lib, ... }:

# ── borgmatic → offsite (BorgBase), ZFS-snapshot, property-driven selection ───
# Offsite backup of the Critical + Precious tiers (docs/BACKUP.md). Selection
# is NOT in this file: borgmatic's ZFS hook backs up every dataset tagged
# `org.torsion.borgmatic:backup=auto`, so the boundary lives on the pool and
# survives dataset renames — mechanics and tagging in BACKUP-BORG.md.

let
  # One string for both: archive_name_format scopes admin-machine prune runs
  # (docs/BACKUP.md's shared-repo footgun), so it must not drift from the label.
  repoLabel = "galactica-offsite";
in
{
  services.borgmatic = {
    enable = true;

    configurations.offsite = {
      # Empty on purpose — selection is entirely property-driven (see header).
      source_directories = [ ];

      # Commands pinned to store paths: the unit runs with a restricted PATH
      # (only coreutils added). `zfs` from boot.zfs.package so it matches the
      # kernel module the pool was imported with.
      zfs = {
        zfs_command = "${config.boot.zfs.package}/bin/zfs";
        mount_command = "${pkgs.util-linux}/bin/mount";
        umount_command = "${pkgs.util-linux}/bin/umount";
      };

      repositories = [
        { path = "ssh://kentmevx@kentmevx.repo.borgbase.com/./repo"; label = repoLabel; }
      ];

      archive_name_format = "${repoLabel}-{now:%Y-%m-%dT%H:%M:%S.%f}";

      encryption_passcommand = "cat ${config.sops.secrets."borgmatic/passphrase".path}";
      ssh_command = "ssh -i ${config.sops.secrets."borgmatic/ssh_key".path} -o UserKnownHostsFile=/var/lib/borgmatic/ssh/known_hosts -o StrictHostKeyChecking=yes";

      compression = "zstd";
      exclude_caches = true;
      exclude_if_present = [ ".nobackup" ];

      # Skip `compact`, NOT `prune`: prune succeeds under an append-only key
      # (manifest-only), so keep_* is enforced nightly; compact is the silent
      # no-op — BorgBase exposes it as a manual "More > Compact repo" action.
      skip_actions = [ "compact" ];

      # Single uniform policy for the mixed Critical/Precious set; the
      # per-tier hot/cold split is deferred — see BACKUP-BORG.md.
      keep_daily = 7;
      keep_weekly = 8;
      keep_monthly = 12;
      keep_yearly = 3;

      checks = [
        { name = "repository"; frequency = "2 weeks"; }
        { name = "archives"; frequency = "1 month"; }
      ];

      # Failure alerting is BorgBase's own inactivity alert (docs/BACKUP.md §6)
      # — no ntfy/uptime_kuma hook, same stance as pegasus.
    };
  };

  sops.secrets."borgmatic/passphrase" = { };
  # Fixed path so known_hosts can sit beside it.
  sops.secrets."borgmatic/ssh_key" = {
    path = "/var/lib/borgmatic/ssh/id_ed25519";
    mode = "0400";
  };

  # 01:30 instead of the packaged midnight. OnCalendar is a LIST directive and
  # this lands as a drop-in, so the leading "" resets the packaged value —
  # without it the timer fires at both times.
  systemd.timers.borgmatic.timerConfig.OnCalendar = [ "" "01:30" ];

  # REQUIRED for the ZFS hook (packaged unit's own comments call these out):
  #  - LoadCredentialEncrypted ships pointing at a systemd-creds secret this
  #    fleet doesn't have; systemd refuses to start with the target absent.
  #    The single empty string renders the bare reset line — mkForce [] would
  #    render nothing and leave the packaged line in force.
  #  - PrivateDevices=yes hides /dev/zfs from zfs(8).
  #  - `zfs snapshot` + mounting it need CAP_SYS_ADMIN; drop-in list
  #    directives union, so naming the upstream two alongside keeps all three.
  systemd.services.borgmatic.serviceConfig = {
    LoadCredentialEncrypted = lib.mkForce [ "" ];
    PrivateDevices = lib.mkForce false;
    CapabilityBoundingSet = [ "CAP_DAC_READ_SEARCH" "CAP_NET_RAW" "CAP_SYS_ADMIN" ];
  };
}
