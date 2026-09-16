# ── pegasus — borgmatic: home directory offsite backup ────────────────────────
# Per docs/BACKUP.md §4b: pegasus had no offsite copy, and iDrive-on-NixOS
# would mean an FHS-wrapped vendor bundle outside the flake — so straight onto
# the real `services.borgmatic` module (declarative, config-checked at build).
{ config, lib, ... }:

let
  hasSops = builtins.pathExists ../../secrets/pegasus.yaml;
in
{
  services.borgmatic = {
    enable = true;

    configurations.pegasus-home = {
      source_directories = [ "/home/z" ];

      # /home is a local subvolume, so the up-while-empty failure mode canary
      # files guard against elsewhere doesn't arise — this guard is enough.
      source_directories_must_exist = true;

      # The Steam game LIBRARY lives on /games (own subvolume, survives
      # reinstalls) — these exclude only the client's home-resident footprint:
      # shader cache, Proton prefixes, login state. Regenerable.
      exclude_patterns = [
        "/home/z/.local/share/Steam"
        "/home/z/.steam"
        "/home/z/.config/discord"
        "/home/z/.lmstudio" # model weights
        "*.gguf"
      ];

      repositories = [
        {
          # Own repo (borg wants one client per repository — BACKUP.md §4b).
          # ⚠ No `encryption:` here: the nixpkgs repository submodule only
          # declares path/label. Not load-bearing — encryption only applies to
          # `repo-create`, and this repo is created via BorgBase's UI; choose
          # repokey-blake2 there.
          path = "ssh://gtsko72z@gtsko72z.repo.borgbase.com/./repo";
          label = "pegasus-home";
        }
      ];

      # Distinct per config — one writer today, but a stale default would bite
      # the moment there isn't.
      archive_name_format = "pegasus-home-{now:%Y-%m-%dT%H:%M:%S.%f}";

      encryption_passcommand = "cat ${config.sops.secrets."borgmatic/passphrase".path}";

      ssh_command = "ssh -i ${config.sops.secrets."borgmatic/ssh_key".path} -o UserKnownHostsFile=/var/lib/borgmatic/ssh/known_hosts -o StrictHostKeyChecking=yes";

      compression = "zstd";

      exclude_caches = true;
      exclude_if_present = [ ".nobackup" ];

      # Enforced nightly — prune runs fine over the append-only key.
      keep_daily = 7;
      keep_weekly = 4;
      keep_monthly = 6;

      # Skip `compact`, NOT `prune`: prune succeeds under an append-only key
      # (manifest-only), so retention stays enforced; compact is the silent
      # no-op — BorgBase exposes it as a manual "More > Compact repo" action.
      skip_actions = [ "compact" ];

      checks = [
        { name = "repository"; frequency = "2 weeks"; }
        { name = "archives"; frequency = "1 month"; }
      ];

      # Failure alerting is BorgBase's own inactivity alert (docs/BACKUP.md §6)
      # — no ntfy/uptime_kuma hook by choice.
    };
  };

  # Extends the sops block in configuration.nix (same hasSops gate).
  # owner = "z" so Vorta (runs as z) can read the same passphrase/key the
  # root service uses; root reads them regardless via CAP_DAC_READ_SEARCH.
  sops = lib.mkIf hasSops {
    secrets."borgmatic/passphrase" = { owner = "z"; };
    secrets."borgmatic/ssh_key" = {
      path = "/var/lib/borgmatic/ssh/id_ed25519";
      owner = "z";
      mode = "0400";
    };
  };

  # The packaged unit ships LoadCredentialEncrypted=borgmatic.pw
  # (systemd-creds/TPM); this fleet uses sops, and systemd refuses to start a
  # unit whose credential target is absent. The single empty string renders
  # the bare reset line — mkForce [] would render nothing and leave the
  # packaged directive in force.
  systemd.services.borgmatic.serviceConfig.LoadCredentialEncrypted = lib.mkForce [ "" ];

  # Cheap fail-closed guard against "backed up an empty mountpoint"
  # (docs/BACKUP.md §3b), even though /home is a local subvolume.
  systemd.services.borgmatic.unitConfig.RequiresMountsFor = [ "/home" ];

  # 01:00 instead of the packaged midnight. OnCalendar is a repeatable
  # directive, so a drop-in ADDS a trigger — the leading "" resets first.
  systemd.timers.borgmatic.timerConfig.OnCalendar = lib.mkForce [
    ""
    "01:00"
  ];

  # Remaining provisioning steps tracked in hosts/pegasus/SECRETS-TODO.md.
}
