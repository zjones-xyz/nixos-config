{ config, pkgs, lib, ... }:

let
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
      };
    };
  };

  # Provision with: sops secrets/memory-alpha.yaml
  # Add a `nut: upsmonPassword: <value>` entry matching whatever password
  # you set for the monitor user on Tower's NUT plugin (mirrors the same
  # key already present in secrets/hopper.yaml).
  sops.secrets."nut/upsmonPassword" = {};
}
