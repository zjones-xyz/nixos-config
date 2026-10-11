{ config, pkgs, lib, ... }:

let
  motdDir = "/var/lib/smartd-motd";

  # Runs as nixpkgs' smartd-notify.sh "mailer". The mail on stdin repeats
  # smartd's SMARTD_* environment, so it is drained and dropped.
  motdHook = pkgs.writeShellScriptBin "smartd-motd-hook" ''
    PATH=${lib.makeBinPath [ pkgs.coreutils pkgs.gnused ]}
    cat > /dev/null

    serial="$(printf '%s' "''${SMARTD_DEVICEINFO:-}" | sed -n 's|.*S/N:\([^,]*\).*|\1|p')"
    disk="$SMARTD_DEVICESTRING"
    [ -n "$serial" ] && disk="$disk *''${serial: -4}"
    msg="''${SMARTD_MESSAGE#"Device: $SMARTD_DEVICESTRING, "}"
    first="$(date -d "@''${SMARTD_TFIRSTEPOCH:-$(date +%s)}" +%F)"
    key="$(printf '%s-%s' "$SMARTD_DEVICE" "$SMARTD_FAILTYPE" | tr -c 'A-Za-z0-9-' '_')"

    mkdir -p ${motdDir}
    printf '⚠ SMART %s: %s (first %s, last %s)\n' \
      "$disk" "$msg" "$first" "$(date +%F)" > "${motdDir}/$key"
  '';
in
{
  # ── SMART tooling, fleet-wide ───────────────────────────────────────────────
  # Imported from common.nix rather than per-host, so `smartctl` exists on every
  # NixOS box by construction and a new host cannot quietly miss it
  # (docs/DISK-DRAWER.md and PLATFORM.md §12 both assume it's there).

  options.homelab.smart.monitor = lib.mkOption {
    type = lib.types.bool;
    default = false;
    description = ''
      Run smartd to poll attached disks and log SMART state.

      Defaults to false because the fleet's Pis boot from SD or USB, which expose
      no SMART data at all — smartd there would monitor nothing and log about it
      on a timer. Enable per-host on machines with real disks behind a controller
      that passes SMART through.

      The `smartctl` binary is installed regardless of this setting; only the
      polling daemon is gated.
    '';
  };

  config = lib.mkMerge [
    # Unconditional: the tool itself, everywhere.
    { environment.systemPackages = [ pkgs.smartmontools ]; }

    (lib.mkIf config.homelab.smart.monitor {
      services.smartd = {
        enable = true;
        autodetect = true;

        # Full attribute set + the drive's own offline collection/autosave.
        # Deliberately no `-s` self-test schedule until alerts go somewhere
        # a person actually reads (see below). `-M daily`: re-warn while a
        # problem persists, which keeps its login-message entry fresh.
        defaults.monitored = "-a -o on -S on -M daily";

        # Wall messages: useless headless, noisy on a desktop.
        notifications.wall.enable = false;
      };
    })

    # ── SMART warnings in the SSH login message ──
    # One file per device and failure type, rewritten on every warning;
    # tmpfiles drops it 3 days (by mtime) after the last one, so a fixed disk
    # clears itself. pam_motd prints the directory after the build line
    # (motd.nix), and nothing at all when it is empty.
    (lib.mkIf config.homelab.smart.monitor {
      services.smartd.notifications.mail = {
        enable = true;
        mailer = "${motdHook}/bin/smartd-motd-hook";
      };
      environment.systemPackages = [ motdHook ];
      systemd.tmpfiles.rules = [ "d ${motdDir} 0755 root root m:3d" ];
      security.pam.services.sshd.rules.session.motd.settings.motd_dir = motdDir;
    })
  ];

  # ⟨Follow-up: also route smartd alerts to ntfy, from motdHook above (it is
  # notifications.mail.mailer now). Not wired yet — the cross-host ntfy URL is
  # unverified, and a guessed endpoint fails silently.⟩
}
