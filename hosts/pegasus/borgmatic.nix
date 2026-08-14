# ── pegasus — borgmatic: home directory offsite backup ────────────────────────
#
# Per `docs/BACKUP.md` §4b: unlike serenity (iDrive already working, switching
# is pure cost), pegasus has no offsite copy at all today, and adopting iDrive
# on NixOS means an FHS wrapper around a vendor script bundle outside the flake
# — exactly what this migration exists to avoid. So pegasus goes straight onto
# borgmatic via the real `services.borgmatic` module: declarative, checked at
# build time (`enableConfigCheck`, on by default), no Docker indirection.
#
# ⚠ NOT evaluated or built from where this was written — no `nix` available in
# that environment. Cross-referenced directly against the nixpkgs module
# source (`nixos/modules/services/backup/borgmatic.nix`) rather than recalled,
# but run `nix flake check` / build this for real before trusting it.
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
      ];

      repositories = [
        {
          # ⟨REPLACE — pegasus's own BorgBase repo. BACKUP.md §4b: borg wants
          # one client per repository, so this is NOT tower-hot/tower-cold;
          # it's a new repo against the same 950 GB budget. Append-only key
          # for pegasus, separate prunable key on the admin machine, same
          # shape as Tower's.⟩
          path = "ssh://REPLACE@REPLACE.repo.borgbase.com/./pegasus-home";
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

      # ⟨Commented out for now — no Kuma push monitor exists yet for this
      # config. Re-enable once one's created, matching Tower's files.⟩
      # uptime_kuma = {
      #   push_url = "https://kuma.hopper.internal/api/push/REPLACE";
      #   states = [ "start" "finish" "fail" ];
      # };

      ntfy = {
        topic = "pegasus-backup";
        server = "https://ntfy.hopper.internal";
        fail = {
          title = "pegasus-home FAILED";
          message = "pegasus's home directory did not back up. Check journalctl -u borgmatic on pegasus.";
          priority = "urgent";
        };
      };
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

  # ⚠ Needs a human, same shape as hosts/pegasus/SECRETS-TODO.md's existing
  # entries — not created here:
  #   1. Generate a dedicated ed25519 keypair for this repo (do NOT reuse
  #      Tower's or z's own SSH key): ssh-keygen -t ed25519 -f pegasus-borgmatic
  #   2. Register the public half as BorgBase's append-only key for
  #      pegasus-home; add the private half to secrets/pegasus.yaml under
  #      borgmatic.ssh_key (sops secrets/pegasus.yaml), and a passphrase under
  #      borgmatic.passphrase.
  #   3. ssh-keyscan the BorgBase host into /var/lib/borgmatic/ssh/known_hosts
  #      on pegasus once (not secret, doesn't need sops).
  #   4. sops updatekeys secrets/pegasus.yaml, commit, deploy.
  # Until all four are done, the systemd timer will fire on schedule and fail
  # loudly against a REPLACE repository URL — that's expected, not a bug.
}
