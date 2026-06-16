{ config, pkgs, lib, ... }:

let
  ntfyTopic = "ups";
  ntfyUrl = "http://127.0.0.1:2586/${ntfyTopic}";

  # Posts UPS power events to the local ntfy instance. Invoked by upssched
  # (see schedulerRules below) with the event name as $1.
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
      -d "hopper UPS event: $event" \
      ${ntfyUrl} || true
  '';

  # upssched config: maps upsmon NOTIFYFLAG events to immediate commands, and
  # arms a timer for sustained on-battery (LOWBATT fires via the driver, but we
  # also flag a prolonged outage after 30s).
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
in
{
  # NUT — hopper is the NUT *server*; the UPS is connected over USB.
  # The same UPS also feeds the modem/router/switch, so this box is the one
  # that sees power events first.
  #
  # Find your UPS once it's plugged in:  nut-scanner -U
  # Most consumer UPSes (CyberPower, APC, Eaton) use the usbhid-ups driver.

  power.ups = {
    enable = true;
    mode = "netserver";   # serve status to network clients (and upsmon locally)

    ups.cyberpower = {
      driver = "usbhid-ups";
      port = "auto";
      description = "Core rack UPS (modem/router/switch/hopper)";
    };

    # upsd listens locally by default; add a LAN listen directive here if you
    # want other machines (memory-alpha, etc.) to monitor this UPS.
    upsd.listen = [ { address = "127.0.0.1"; } ];

    upsmon = {
      monitor.cyberpower = {
        system = "cyberpower@localhost";
        # master = this host powers down the UPS at the end of a shutdown.
        type = "master";
        user = "upsmon";
        passwordFile = config.sops.secrets."nut/upsmonPassword".path;
      };
      settings = {
        # Route every notification through upssched so we can debounce/route
        # to ntfy from one place.
        NOTIFYCMD = "${pkgs.nut}/bin/upssched";
        # SYSLOG+EXEC so events both log and trigger NOTIFYCMD.
        NOTIFYFLAG = [
          "ONBATT SYSLOG+EXEC"
          "ONLINE SYSLOG+EXEC"
          "LOWBATT SYSLOG+EXEC"
          "COMMBAD SYSLOG+EXEC"
          "COMMOK SYSLOG+EXEC"
        ];
      };
    };

    users.upsmon = {
      passwordFile = config.sops.secrets."nut/upsmonPassword".path;
      upsmon = "master";
    };

    schedulerRules = "${upsschedConf}";
  };

  # upssched needs a writable runtime dir for its pipe/lock.
  systemd.tmpfiles.rules = [
    "d /run/nut 0750 nut nut -"
  ];

  sops.secrets."nut/upsmonPassword" = {};
}
