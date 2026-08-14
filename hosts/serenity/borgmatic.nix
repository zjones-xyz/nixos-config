# ── serenity — borgmatic: home directory offsite backup ───────────────────────
#
# ⚠ This accelerates serenity ahead of `docs/BACKUP.md` §4b's own
# recommendation, which was to DEFER serenity: it already runs three working
# offsite paths (iDrive + two rotated Time Machine drives) and "is under no
# pressure in any of this... the best-covered machine in the fleet." §4b's
# whole argument for putting pegasus on borgmatic first and serenity later was
# sequencing — gather operational evidence from Tower/pegasus before touching
# something that already works. If this was a deliberate call to move sooner,
# consider updating that section's timeline so it doesn't read as still-current
# guidance being quietly ignored.
#
# ⚠⚠ UNLIKE pegasus, there is no `services.borgmatic` for nix-darwin — checked
# directly against nix-darwin's module-list.nix, not recalled: no borgmatic
# module exists there. This file hand-rolls the equivalent of what that module
# does for NixOS: install the package, write the config to /etc, and drive it
# from a launchd daemon instead of a systemd timer. Structure verified against
# nix-darwin's actual module sources (modules/system/etc.nix for
# environment.etc, modules/launchd/default.nix for launchd.daemons) rather
# than assumed — but NONE of this has been evaluated or built anywhere, let
# alone run on a Mac. Treat it as a draft in the same sense as Tower's
# borgmatic files originally were.
#
# ⚠ Passphrase/SSH key delivery is a plain file under z's home, NOT sops-nix —
# serenity has no sops-nix module wired into configuration.nix today (only an
# ad hoc SOPS_AGE_KEY_FILE for the `sops` CLI itself, in home.nix). Wiring real
# sops-nix onto serenity is a bigger, separate change than "add backup config"
# asked for, and serenity is very likely the fleet's admin machine BACKUP.md §5
# keeps referring to — the one holding the age key everything else is
# encrypted to. Circular custody for its OWN secrets is exactly the unresolved
# problem §5 flags for Tower; not solved here either. Matches how serenity
# already handles secrets today: manual files, not automation.
{ pkgs, ... }:

{
  environment.systemPackages = [ pkgs.borgmatic ];

  environment.etc."borgmatic.d/serenity-home.yaml".text = ''
    source_directories:
        - /Users/z

    # Local APFS boot volume, not a network share — same reasoning as
    # pegasus's borgmatic.nix for skipping a canary file here.
    source_directories_must_exist: true

    # macOS puts essentially everything app-managed under ~/Library — caches,
    # Application Support, Containers, saved application state. This already
    # covers Steam too (macOS Steam installs to
    # ~/Library/Application Support/Steam, not a separate top-level
    # directory), so there's no separate Steam exclusion needed here the way
    # pegasus's config needs one.
    exclude_patterns:
        - /Users/z/Library

    repositories:
        # ⟨REPLACE — serenity's own BorgBase repo, same "one client per
        # repository" reasoning as pegasus's. Append-only key for serenity,
        # separate prunable key on the admin machine.⟩
        - path: ssh://REPLACE@REPLACE.repo.borgbase.com/./serenity-home
          label: serenity-home
          encryption: repokey-blake2

    archive_name_format: 'serenity-home-{now:%Y-%m-%dT%H:%M:%S.%f}'

    encryption_passcommand: cat /Users/z/.config/borgmatic/passphrase

    ssh_command: ssh -i /Users/z/.config/borgmatic/ssh/id_ed25519 -o UserKnownHostsFile=/Users/z/.config/borgmatic/ssh/known_hosts -o StrictHostKeyChecking=yes

    compression: zstd

    exclude_caches: true
    exclude_if_present:
        - .nobackup

    # ⟨Proposal, not decided — same status as Tower's and pegasus's numbers.⟩
    keep_daily: 7
    keep_weekly: 4
    keep_monthly: 6

    checks:
        - name: repository
          frequency: 2 weeks
        - name: archives
          frequency: 1 month

    # ⟨Commented out for now — no Kuma push monitor exists yet for this
    # config. Re-enable once one's created, matching Tower's and pegasus's
    # files.⟩
    # uptime_kuma:
    #     push_url: https://kuma.hopper.internal/api/push/REPLACE
    #     states:
    #         - start
    #         - finish
    #         - fail

    ntfy:
        topic: serenity-backup
        server: https://ntfy.hopper.internal
        fail:
            title: serenity-home FAILED
            message: serenity's home directory did not back up. Check the launchd job's log.
            priority: urgent
  '';

  # launchd.daemons (system-level, /Library/LaunchDaemons) rather than
  # launchd.agents (per-user, only alive during a GUI session) — a backup
  # should run on schedule whether or not anyone's logged in. Runs as z via
  # UserName so it reads /Users/z with normal permissions, not root.
  launchd.daemons.borgmatic-serenity-home = {
    script = ''
      exec ${pkgs.borgmatic}/bin/borgmatic -c /etc/borgmatic.d/serenity-home.yaml create
    '';
    serviceConfig = {
      UserName = "z";
      # No StartCalendarInterval yet, same discipline as Tower's compose.yaml
      # (CRON left commented) and pegasus's borgmatic.nix (systemd timer's
      # default schedule not yet confirmed to fit): time the first run by
      # hand before trusting anything unattended. Add e.g.
      #   StartCalendarInterval = { Hour = 2; Minute = 0; };
      # once that's known. RunAtLoad = false so loading this daemon (every
      # boot/activation) doesn't itself trigger a run.
      RunAtLoad = false;
      StandardOutPath = "/Users/z/.config/borgmatic/borgmatic.log";
      StandardErrorPath = "/Users/z/.config/borgmatic/borgmatic.log";
    };
  };

  # ⚠ Needs a human — nothing here creates any of this:
  #   1. Generate a dedicated ed25519 keypair (not Tower's, not pegasus's, not
  #      z's own SSH key): ssh-keygen -t ed25519 -f serenity-borgmatic -N ""
  #   2. Create the serenity-home repo on BorgBase, register the public half
  #      as its append-only key.
  #   3. On serenity: mkdir -p ~/.config/borgmatic/ssh, chmod 700
  #      ~/.config/borgmatic, put the private key at
  #      ~/.config/borgmatic/ssh/id_ed25519 (chmod 600), a passphrase at
  #      ~/.config/borgmatic/passphrase (chmod 600, distinct from every other
  #      host's), and ssh-keyscan the BorgBase host into
  #      ~/.config/borgmatic/ssh/known_hosts.
  #   4. darwin-rebuild switch, then run the first backup by hand:
  #      sudo launchctl kickstart -k system/org.nixos.borgmatic-serenity-home
  #      (or plain `borgmatic -c /etc/borgmatic.d/serenity-home.yaml create`
  #      as z, to test without going through launchd first).
}
