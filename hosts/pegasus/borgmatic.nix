# ── pegasus — borgmatic: home directory offsite backup ────────────────────────
#
# Per `docs/BACKUP.md` §4b: unlike serenity (iDrive already working, switching
# is pure cost), pegasus has no offsite copy at all today, and adopting iDrive
# on NixOS means an FHS wrapper around a vendor script bundle outside the flake
# — exactly what this migration exists to avoid. So pegasus goes straight onto
# borgmatic via the real `services.borgmatic` module: declarative, checked at
# build time (`enableConfigCheck`, on by default), no Docker indirection.
#
# Validated 2026-08-22 against the pinned nixpkgs tree's borgmatic 2.1.5: the
# generated YAML was hand-translated and run through `borgmatic config
# validate` directly, and `nix flake check` passes for pegasus with this
# imported. Still needs a real `nixos-rebuild switch` on the box itself.
#
# Same per-service-file spirit as Tower's `hosts/galactica/borgmatic/*.yaml`
# (BACKUP.md §4c/§4d's "unit of configuration" reasoning), kept as its own
# file rather than inlined in configuration.nix because — like Tower's — it's
# dense enough to want its own home.
{ config, lib, ... }:

let
  hasSops = builtins.pathExists ../../secrets/pegasus.yaml;
in
{
  services.borgmatic = {
    enable = true;

    configurations.pegasus-home = {
      source_directories = [ "/home/z" ];

      # Reasonable here in a way it wasn't on Tower: /home is a subvolume of
      # pegasus's own root btrfs pool, not a FUSE/NFS share that can be up
      # while empty. No canary file (see appdata.yaml's for the contrast) —
      # the failure mode canaries guard against doesn't really arise for a
      # local root filesystem the way it does for Unraid's shfs layer.
      source_directories_must_exist = true;

      # ⚠ Steam's actual game LIBRARY already isn't under /home at all — it
      # lives on the dedicated @games btrfs subvolume, mounted at /games
      # (hosts/pegasus/disko.nix, modules/nixos/gaming.nix), specifically so
      # it survives reinstalls independent of home. These exclusions are for
      # the Steam CLIENT's own home-resident footprint: shader cache,
      # per-title compatdata/Proton prefixes for anything NOT pointed at
      # /games, screenshots, login state — regenerable/re-downloadable, not
      # worth the offsite budget.
      exclude_patterns = [
        "/home/z/.local/share/Steam"
        "/home/z/.steam"
        "/home/z/.config/discord"
        "/home/z/.lmstudio"

        # Catch-all for model weights wherever they end up next, not just
        # today's .lmstudio/models — borg's default fnmatch style matches `*`
        # across path separators, so this hits any .gguf regardless of depth.
        "*.gguf"
      ];

      repositories = [
        {
          # pegasus's own BorgBase repo (created 2026-08-26). BACKUP.md §4b:
          # borg wants one client per repository, so this is NOT
          # tower-hot/tower-cold; it's its own repo against the same 950 GB
          # budget. Append-only key for pegasus, separate prunable key on the
          # admin machine, same shape as Tower's.
          path = "ssh://gtsko72z@gtsko72z.repo.borgbase.com/./repo";
          label = "pegasus-home";
          # ⚠ No `encryption:` here, unlike Tower's YAML files. The nixpkgs
          # module's `repository` submodule only declares `path`/`label` (no
          # freeform fallback on that inner submodule — checked against the
          # module source directly), so `encryption: repokey-blake2` can't be
          # set through this option even though borgmatic's own schema
          # supports it per-repository. Not load-bearing: `encryption` only
          # applies to borgmatic's own `repo-create` action, and — same as
          # Tower — this repo is created via BorgBase's UI, where the
          # encryption mode is chosen directly. Use repokey-blake2 there, for
          # the same reason as Tower's files (Zen 3/4-class AES-NI without
          # needing the SHA extensions — ⟨assumed for pegasus's Ryzen, not
          # measured; recheck against DECISIONS.md/HARDWARE-MAP.md if it
          # matters⟩).
        }
      ];

      # Distinct per config, same reason as Tower's files — this repo has one
      # writer today, but a stale default would bite the moment it doesn't.
      archive_name_format = "pegasus-home-{now:%Y-%m-%dT%H:%M:%S.%f}";

      encryption_passcommand = "cat ${config.sops.secrets."borgmatic/passphrase".path}";

      ssh_command = "ssh -i ${config.sops.secrets."borgmatic/ssh_key".path} -o UserKnownHostsFile=/var/lib/borgmatic/ssh/known_hosts -o StrictHostKeyChecking=yes";

      # Let borg compress — same reasoning as Tower's documents.yaml. No
      # database hooks here, so none of BACKUP.md §4d's pre-compression
      # footgun applies; this is a plain filesystem tree.
      compression = "zstd";

      exclude_caches = true;
      exclude_if_present = [ ".nobackup" ];

      # ⟨Proposal, not decided — same status as Tower's numbers. A desktop's
      # home directory churns less than Tower's documents share but is worth
      # more than zero versioning.⟩
      keep_daily = 7;
      keep_weekly = 4;
      keep_monthly = 6;

      checks = [
        { name = "repository"; frequency = "2 weeks"; }
        { name = "archives"; frequency = "1 month"; }
      ];

      # Monitoring deliberately deferred to BorgBase's own inactivity alerting
      # (docs/BACKUP.md §6: "Turn on BorgBase's own inactivity alerting... as
      # a heartbeat that does not depend on hopper being up") rather than
      # ntfy/Uptime Kuma hooks — Zoe's call, 2026-08-22, same reasoning as why
      # this config carries no uptime_kuma block either: no point wiring a
      # second monitor when the provider's own is a config-free toggle in its
      # UI. Revisit if that stops being enough (e.g. wanting a signal that
      # doesn't depend on BorgBase itself being reachable/up).
      # ntfy = {
      #   topic = "pegasus-backup";
      #   server = "https://ntfy.hopper.internal";
      #   fail = {
      #     title = "pegasus-home FAILED";
      #     message = "pegasus's home directory did not back up. Check journalctl -u borgmatic on pegasus.";
      #     priority = "urgent";
      #   };
      # };
    };
  };

  # ── sops-nix ────────────────────────────────────────────────────────────────
  # Extends the existing sops block in configuration.nix (same hasSops gate,
  # same pattern as the tailscale authKey / z's SSH key already there).
  sops = lib.mkIf hasSops {
    secrets."borgmatic/passphrase" = { };
    secrets."borgmatic/ssh_key" = {
      path = "/var/lib/borgmatic/ssh/id_ed25519";
      mode = "0400";
    };
  };

  # The upstream borgmatic.service ships `LoadCredentialEncrypted=borgmatic.pw`
  # (systemd-creds, TPM-backed) as its default secret-delivery mechanism — this
  # fleet uses sops-nix for every other secret, not systemd-creds, and without
  # this override the unit fails to start outright (systemd refuses to start a
  # service whose LoadCredentialEncrypted target is missing). Verified
  # directly (2026-08-22) that a `[""]` override is what's needed: NixOS's
  # systemd module renders `systemd.services.<name>.serviceConfig` as a
  # drop-in layered ON TOP of the package-provided unit — drop-ins add to
  # list-type directives rather than replacing them, so `mkForce []` (an empty
  # Nix list) renders no line at all and leaves the upstream directive
  # in effect. A single empty-string list element renders the bare
  # `LoadCredentialEncrypted=` line systemd itself treats as "clear everything
  # assigned so far" — confirmed by building this repo's actual generated
  # unit and reading the rendered drop-in.
  systemd.services.borgmatic.serviceConfig.LoadCredentialEncrypted = lib.mkForce [ "" ];

  # /home is a subvolume mount of pegasus's own root pool (hosts/pegasus/
  # disko.nix), not expected to ever be absent — but this is the cheap,
  # declarative guard docs/BACKUP.md §3b calls out for the "backup ran,
  # reported success, and silently backed up an empty/unmounted directory"
  # failure mode, so it costs nothing to have it fail closed regardless.
  systemd.services.borgmatic.unitConfig.RequiresMountsFor = [ "/home" ];

  # Provisioning status: keypair generated, pegasus-home repo created on
  # BorgBase with the append-only key registered, and the passphrase/ssh_key
  # secrets are in secrets/pegasus.yaml (2026-08-26). Remaining steps tracked
  # in hosts/pegasus/SECRETS-TODO.md — ssh-keyscan into known_hosts, turn on
  # BorgBase's inactivity alerting, and run the first backup by hand.
}
