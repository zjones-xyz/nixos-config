{ config, pkgs, lib, ... }:

# ─────────────────────────────────────────────────────────────────────────────
# Home Assistant — HA Container, compose declared in Nix (memory-alpha).
# ─────────────────────────────────────────────────────────────────────────────
# Deliberately NOT nixpkgs' services.home-assistant: that is a Core install,
# which upstream does not support, and the pinned channel runs ~4 months behind
# HA's monthly releases. docs/HOME-ASSISTANT-MIGRATION.md §4 has the argument
# and the condition under which it reverses.
#
# Same shape as traefik.nix/arcane.nix: a pkgs.writeText compose file driven by
# a systemd unit, image pinned in-repo so a bump is a reviewed commit.
# (Not dockge.nix — PR #100 retires it fleet-wide in favour of Arcane.)

let
  # Exact release, never `stable` — see the header. Bumping is a PR.
  image = "ghcr.io/home-assistant/home-assistant:2026.9.2";

  composeFile = pkgs.writeText "home-assistant-compose.yml" ''
    services:
      home-assistant:
        image: ${image}
        container_name: home-assistant
        restart: unless-stopped

        # ⚠ Host networking is load-bearing, not laziness: HA's discovery
        # (mDNS/SSDP, HomeKit, ESPHome, Chromecast) needs L2 broadcast, which a
        # bridge network does not carry. The cost is that Traefik labels don't
        # work here — the router lives in traefik.nix's file provider instead,
        # exactly as Jellyfin's does.
        network_mode: host

        environment:
          - TZ=${config.time.timeZone}

        volumes:
          - /home/z/home-assistant/config:/config

        # ⚠ Two things HA's own container docs tell you to add are omitted on
        # purpose, and a reader "fixing" that would undo a decision:
        #   - `privileged: true` and any `devices:` — the Zigbee coordinator is
        #     network-attached, so no USB device is passed through.
        #   - `/run/dbus` — Bluetooth is served by ESPHome BT proxies, not by a
        #     local adapter, so BlueZ is not plumbed into the container.
        # MIGRATION.md §6 argues both; reversing either means reading it first.
  '';
in
{
  # ⚠ 8123 is deliberately NOT opened. Host networking binds it on every
  # interface, but the only intended path in is Traefik, which reaches it over
  # the already-trusted br-proxy bridge (traefik.nix).

  systemd.services.home-assistant = {
    description = "Home Assistant";
    after = [ "network-online.target" "docker.service" ];
    wants = [ "network-online.target" "docker.service" ];
    wantedBy = [ "multi-user.target" ];

    serviceConfig = {
      User = "z";
      Restart = "on-failure";
      RestartSec = "10s";
      # ⚠ The chown is the TOP directory only, never `-R`. HA runs as root
      # inside the container and owns /config; a recursive chown would fight
      # that and cost O(config) on every start once the recorder DB is in
      # there. One level keeps z's home navigable at no cost.
      ExecStartPre = "+${pkgs.bash}/bin/bash -c 'mkdir -p /home/z/home-assistant/config && chown z:users /home/z/home-assistant'";
      ExecStop = "${config.virtualisation.docker.package}/bin/docker compose -f ${composeFile} --project-name home-assistant down";
    };

    script = ''
      exec ${config.virtualisation.docker.package}/bin/docker compose -f ${composeFile} --project-name home-assistant up --remove-orphans
    '';
  };
}
