{ config, pkgs, lib, ... }:

let
  ntfyTopic = "ups";
  ntfyUrl = "http://127.0.0.1:2586/${ntfyTopic}";

  # Posts UPS power events to memory-alpha's own local ntfy instance.
  # Mirrors hopper's notifyScript in nut.nix, just with a different message
  # prefix so events from the two UPSes are distinguishable in ntfy.
  notifyScript = pkgs.writeShellScript "ups-notify" ''
    event="$1"
    case "$event" in
      onbattery)  title="UPS on battery";        prio="high";    tags="warning,battery" ;;
      online)     title="UPS power restored";     prio="default"; tags="white_check_mark" ;;
      lowbattery) title="UPS LOW battery";        prio="urgent";  tags="rotating_light" ;;
      commbad)    title="UPS comms lost";          prio="high";    tags="warning" ;;
      commok)     title="UPS comms restored";      prio="default"; tags="white_check_mark" ;;
      *)          title="UPS event: $event";       prio="default"; tags="electric_plug" ;;
    esac
    ${pkgs.curl}/bin/curl -fsS \
      -H "Title: $title" \
      -H "Priority: $prio" \
      -H "Tags: $tags" \
      -d "memory-alpha UPS event: $event (via Tower)" \
      ${ntfyUrl} || true
  '';

  upsschedConf = pkgs.writeText "upssched.conf" ''
    CMDSCRIPT ${pkgs.writeShellScript "upssched-cmd" ''
      ${notifyScript} "$1"
    ''}
    PIPEFN /run/nut/upssched.pipe
    LOCKFN /run/nut/upssched.lock

    AT ONBATT     * EXECUTE onbattery
    AT ONLINE     * EXECUTE online
    AT LOWBATT    * EXECUTE lowbattery
    AT COMMBAD    * EXECUTE commbad
    AT COMMOK     * EXECUTE commok
  '';

  # TODO confirm towerUpsName against Tower's Unraid NUT plugin settings
  # page before deploying (commonly "ups", but verify).
  towerUpsName = "ups";
  towerMonitorUser = "monuser";
in
{
  # NUT client — Tower (Unraid, tower.internal) is the NUT server for its
  # own UPS, which is on the same rack as memory-alpha. This is a distinct
  # UPS from the one hopper monitors (see modules/nixos/nut.nix), which only
  # covers hopper/modem/router/switch on a separate rack.
  #
  # memory-alpha is a "secondary" monitor: it only needs to shut *itself*
  # down cleanly when Tower signals FSD (forced shutdown, i.e. battery
  # critical) — Tower remains the primary responsible for the UPS itself.
  power.ups = {
    enable = true;
    mode = "netclient";

    upsmon = {
      monitor.tower = {
        system = "${towerUpsName}@tower.internal";
        type = "secondary";
        user = towerMonitorUser;
        passwordFile = config.sops.secrets."nut/upsmonPassword".path;
      };
      settings = {
        # Without this, upsmon's default on FSD is a no-op-ish shutdown
        # hook — make sure a sustained outage actually powers this host
        # off cleanly instead of leaving it to get hard-cut when Tower's
        # UPS battery finally runs out.
        SHUTDOWNCMD = "${pkgs.systemd}/bin/systemctl poweroff";

        NOTIFYCMD = "${pkgs.nut}/bin/upssched";
        NOTIFYFLAG = [
          [ "ONBATT" "SYSLOG+EXEC" ]
          [ "ONLINE" "SYSLOG+EXEC" ]
          [ "LOWBATT" "SYSLOG+EXEC" ]
          [ "COMMBAD" "SYSLOG+EXEC" ]
          [ "COMMOK" "SYSLOG+EXEC" ]
        ];
      };
    };

    schedulerRules = "${upsschedConf}";
  };

  systemd.tmpfiles.rules = [
    "d /run/nut 0750 nut nut -"
  ];

  # Provision with: sops secrets/memory-alpha.yaml
  # Add a `nut: upsmonPassword: <value>` entry matching whatever password
  # you set for the monitor user on Tower's NUT plugin (mirrors the same
  # key already present in secrets/hopper.yaml).
  sops.secrets."nut/upsmonPassword" = {};
}
