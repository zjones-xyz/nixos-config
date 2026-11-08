{ config, pkgs, lib, ... }:

let
  cfg = config.homelab.alerts;

  # Sendmail-shaped on purpose: ZED and smartd can only hand a message to a
  # mailer, so this reads headers + blank line + body on stdin, ignores its
  # arguments, and posts Subject → Title, the rest → body. The token is read
  # at run time so it never lands in the store (zed.rc is a store file).
  ntfyAlert = pkgs.writeShellApplication {
    name = "ntfy-alert";
    runtimeInputs = [ pkgs.curl pkgs.coreutils pkgs.gnused ];
    text = ''
      msg="$(cat)"
      title="$(printf '%s\n' "$msg" | sed -n '1,/^$/{s/^Subject: *//p}' | head -n1)"
      if [ -n "$title" ]; then
        body="$(printf '%s\n' "$msg" | sed '1,/^$/d')"
      else
        body="$msg"
      fi
      auth=()
      ${lib.optionalString (cfg.tokenFile != null) ''
        auth=(-H "Authorization: Bearer $(cat ${lib.escapeShellArg cfg.tokenFile})")
      ''}
      exec curl -fsS --max-time 30 --retry 3 -o /dev/null "''${auth[@]}" \
        -H "Title: ''${title:-${config.networking.hostName} alert}" \
        -H "Tags: ${config.networking.hostName}" \
        -H "Priority: ''${NTFY_PRIORITY:-high}" \
        --data-binary "$body" \
        ${lib.escapeShellArg "${cfg.url}/${cfg.topic}"}
    '';
  };
in
{
  # ── Host alerts → ntfy ──────────────────────────────────────────────────────
  # One path for "something on this box needs a human": ZED pool events, smartd
  # disk warnings, and `onFailure` of any unit pointed at notify-failure@.
  options.homelab.alerts = {
    enable = lib.mkEnableOption "host alerts (ZED, smartd, failed units) posted to ntfy";

    url = lib.mkOption {
      type = lib.types.str;
      default = "https://ntfy.monitor.zjones.dev";
      description = "ntfy server base URL (memory-alpha's monitoring stack).";
    };

    topic = lib.mkOption {
      type = lib.types.str;
      default = "homelab-alerts";
      description = "Topic every host's alerts post to; the host name rides along as a tag.";
    };

    tokenFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = ''
        File holding an ntfy access token (`tk_…`) with write access to the
        topic, e.g. a sops secret path. null publishes anonymously, which only
        works while the server's default access lets everyone write the topic.
      '';
    };

    package = lib.mkOption {
      type = lib.types.package;
      readOnly = true;
      default = ntfyAlert;
      description = "The `ntfy-alert` sender, for other modules' hooks.";
    };
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [ ntfyAlert ];

    # `onFailure = [ "notify-failure@%n.service" ];` on any unit worth a page.
    systemd.services."notify-failure@" = {
      description = "Post the failure of %i to ntfy";
      serviceConfig.Type = "oneshot";
      scriptArgs = "%i";
      script = ''
        { printf 'Subject: %s failed on %s\n\n' "$1" ${lib.escapeShellArg config.networking.hostName}
          ${pkgs.systemd}/bin/journalctl -u "$1" -n 20 --no-pager -o cat
        } | ${lib.getExe ntfyAlert}
      '';
    };

    # ZED: pool state changes, device faults, errors found by scrub/resilver.
    # Not services.zfs.zed.enableMail — that wants a sendmail setuid wrapper.
    services.zfs.zed.settings = lib.mkIf config.boot.zfs.enabled {
      ZED_EMAIL_ADDR = [ "ntfy" ]; # any value: ZED skips email without one
      ZED_EMAIL_PROG = lib.getExe ntfyAlert;
      ZED_EMAIL_OPTS = "@ADDRESS@"; # no @SUBJECT@ → ZED adds a Subject: header
      ZED_NOTIFY_VERBOSE = false; # problems only, not every clean scrub
    };

    # smartd: its mail notification pipes a Subject:-headed message to `mailer`.
    services.smartd.notifications.mail = lib.mkIf config.homelab.smart.monitor {
      enable = true;
      recipient = "ntfy";
      mailer = lib.getExe ntfyAlert;
    };
  };
}
