{ config, pkgs, lib, ... }:

# ── memory-alpha — borgmatic: service data offsite to BorgBase ────────────────
#
# memory-alpha's first backup of any kind. It holds the Arcane manager DB, the
# Beszel hub's history, Scrutiny's InfluxDB, dockge's stacks, Traefik's certs
# and `dashboard-auth` htpasswd, and Jellyfin's users DB — none of which existed
# anywhere else. Same shape as hosts/pegasus/borgmatic.nix (path-driven, no ZFS
# hook: this host is btrfs), not galactica's property-driven config.
#
# The `enabled` switch below gates the whole module: while false it contributes
# nothing at all, so the sops secrets are not declared and a switch before their
# values exist cannot fail activation.

let
  # ⚠ THE one switch. false = this module contributes nothing at all (important:
  # the sops secrets below are only declared when enabled, so a switch before
  # their values exist in secrets/memory-alpha.yaml cannot fail activation).
  # Live since 2026-09-04.
  enabled = true;

  repoLabel = "memory-alpha";

  # The borgmatic unit runs with a restricted PATH (the NixOS module only adds
  # coreutils), so a bare `sqlite3` would not resolve — same reason galactica's
  # ZFS hook pins zfs/mount/umount to store paths.
  sqlite3 = "${pkgs.sqlite}/bin/sqlite3";
  db = path: { name = builtins.baseNameOf path; inherit path; sqlite_command = sqlite3; };
in
lib.optionalAttrs enabled
{
  services.borgmatic = {

    enable = true;

    configurations.offsite = {
      # Whole-home plus Jellyfin's state, minus the regenerable bulk below.
      # Deliberately NOT an enumerated list of the ~15 service directories:
      # those drift every time a stack is added, and a missing one fails
      # silently by simply not being backed up. Exclusions are the safer thing
      # to maintain — a stale exclusion is visible, a missing include is not.
      source_directories = [
        "/home/z"
        "/var/lib/jellyfin"
      ];

      # ⭐ The big one: /home/z/ollama is 6.5 G of Ollama model blobs and is
      # ~83% of this host's disk usage. Ollama stores models content-addressed
      # (models/blobs/sha256-…), NOT as .gguf files, so pegasus's `*.gguf`
      # pattern would not catch any of it — the path exclusion is doing the
      # real work here. All of it is re-pullable with `ollama pull`.
      # Everything else here is cache or lives elsewhere: jellyfin/metadata is
      # 1.9 G of re-downloadable artwork, introskipper-cache.db is 93 M (the
      # largest single DB on the box, and pure cache), nixos-config is a clone
      # of this repo, arcane.backup is the pre-2.10.1 snapshot.
      # Measured 2026-09-03: ~10 G total -> ~1.35 G kept.
      exclude_patterns = [
        "/home/z/ollama"
        "/home/z/nixos-config"
        "/home/z/arcane.backup"
        "/home/z/.cache"
        "/home/z/ntfy/cache"
        "/home/z/tdarr/cache"
        "/home/z/tdarr/logs"
        "/home/z/tdarr/output"
        "/home/z/tdarr/staging"
        "/var/lib/jellyfin/metadata"
        "/var/lib/jellyfin/transcodes"
        "/var/lib/jellyfin/log"
        "/var/lib/jellyfin/data/introskipper/introskipper-cache.db"
        "*.gguf"
      ];
      exclude_caches = true;
      exclude_if_present = [ ".nobackup" ];

      # ── SQLite dumps ─────────────────────────────────────────────────────────
      # docs/BACKUP.md §4d: a file-level copy of a live database is not a
      # backup. Every service on this host is SQLite, so each gets a real
      # `.backup` dump alongside the file copy; the dump is the restore path.
      # jellyfin.db is the one that matters most — it holds the users the
      # nixflix D-lite plan has to absorb rather than recreate.
      # Paths confirmed live 2026-09-03; note there is no library.db (modern
      # Jellyfin consolidated it into jellyfin.db).
      sqlite_databases = [
        (db "/var/lib/jellyfin/data/jellyfin.db")
        (db "/home/z/uptime-kuma/kuma.db")
        (db "/home/z/arcane/data/arcane.db")
        (db "/home/z/beszel/data.db")
        (db "/home/z/beszel/auxiliary.db")
        (db "/home/z/open-webui/webui.db")
        (db "/home/z/dockge/data/dockge.db")
      ];

      repositories = [
        { path = "ssh://whwb4nzs@whwb4nzs.repo.borgbase.com/./repo"; label = repoLabel; }
      ];

      archive_name_format = "${repoLabel}-{now:%Y-%m-%dT%H:%M:%S.%f}";

      encryption_passcommand = "cat ${config.sops.secrets."borgmatic/passphrase".path}";
      ssh_command = "ssh -i ${config.sops.secrets."borgmatic/ssh_key".path} -o UserKnownHostsFile=/var/lib/borgmatic/ssh/known_hosts -o StrictHostKeyChecking=yes";

      compression = "zstd";

      # Skip `compact`, NOT `prune` — same as galactica and pegasus. Prune
      # succeeds under an append-only key (it only marks archives deleted);
      # `compact` is the silent no-op, and BorgBase exposes that as a manual
      # "More > Compact repo" action.
      skip_actions = [ "compact" ];

      # Service config and DBs: small, high-churn, worth depth. Nothing here is
      # large enough for retention to be a budget question (~1.35 G).
      keep_daily = 14;
      keep_weekly = 8;
      keep_monthly = 12;

      checks = [
        { name = "repository"; frequency = "2 weeks"; }
        { name = "archives"; frequency = "1 month"; }
      ];
    };
  };

  sops.secrets."borgmatic/passphrase" = { };
  sops.secrets."borgmatic/ssh_key" = {
    path = "/var/lib/borgmatic/ssh/id_ed25519";
    mode = "0400";
  };

  # 02:30, an hour after galactica's 01:30, so the two hosts don't contend for
  # the same upstream. OnCalendar is a list directive and this lands as a
  # drop-in, so the leading "" resets the packaged daily/midnight value —
  # without it the timer fires at both times.
  systemd.timers.borgmatic.timerConfig.OnCalendar = [ "" "02:30" ];

  # The packaged unit ships LoadCredentialEncrypted=borgmatic.pw
  # (systemd-creds/TPM); this fleet uses sops, and systemd refuses to start a
  # unit whose credential target is absent. The single empty-string element
  # renders the bare `LoadCredentialEncrypted=` reset line — mkForce [] would
  # render nothing and leave the packaged line in force. Same as pegasus.
  systemd.services.borgmatic.serviceConfig = {
    LoadCredentialEncrypted = lib.mkForce [ "" ];

    # CAP_DAC_OVERRIDE is REQUIRED for the SQLite hook, and its absence is not
    # obvious: the packaged unit ships CapabilityBoundingSet=CAP_DAC_READ_SEARCH
    # CAP_NET_RAW, and root's power to ignore file modes comes from
    # CAP_DAC_OVERRIDE specifically. Without it borgmatic runs as a root that can
    # READ anything but WRITE only what it owns by mode bits — and `sqlite3 .dump`
    # is not read-only: opening a WAL-mode database creates -shm/-wal sidecars
    # next to it. /var/lib/jellyfin/data is owned by jellyfin, so the dump failed
    # with "attempt to write a readonly database (8)". It would have hit all
    # seven DBs; jellyfin.db was simply first. Drop-in list directives union, so
    # naming the upstream two alongside keeps all three.
    CapabilityBoundingSet = [ "CAP_DAC_READ_SEARCH" "CAP_NET_RAW" "CAP_DAC_OVERRIDE" ];
  };

  # ── Bring-up checklist (owner) ───────────────────────────────────────────────
  # 1. Create a BorgBase repo (repokey-blake2) + an append-only SSH key.
  # 2. Set `repositories.path` above to the real URL.
  # 3. `sops-hostkey secrets/memory-alpha.yaml` -> add borgmatic/passphrase and
  #    borgmatic/ssh_key (the private half of the append-only key).
  # 4. sudo mkdir -p /var/lib/borgmatic/ssh
  #    sudo ssh-keyscan <host>.repo.borgbase.com | sudo tee /var/lib/borgmatic/ssh/known_hosts
  # 5. Init the repo: temporarily flip the key to full access in BorgBase,
  #    `sudo borgmatic repo-create --encryption repokey-blake2`, flip it back.
  # 6. Flip `enable = true` above, nrs, then `sudo systemctl start borgmatic`.
  # 7. Turn on BorgBase inactivity alerting for the repo.
}
