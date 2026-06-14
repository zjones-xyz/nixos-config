{ config, pkgs, lib, ... }:

{
  # Newt — Pangolin tunnel agent.
  # Creates a persistent tunnel to pangolin.zjones.xyz so public-facing
  # Docker services on memory-alpha are reachable without opening inbound ports.
  # Runs as a systemd service (not Docker) so it's up before containers start.

  sops.secrets."newt/clientSecret" = {};

  systemd.services.newt = {
    description = "Pangolin Newt tunnel agent";
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    wantedBy = [ "multi-user.target" ];

    # Shell script so we can read the sops-decrypted secret at runtime
    script = ''
      exec ${pkgs.fosrl-newt}/bin/newt \
        --id n83mhpnryi0lrid \
        --secret "$(cat ${config.sops.secrets."newt/clientSecret".path})" \
        --endpoint https://pangolin.zjones.xyz
    '';

    serviceConfig = {
      Restart = "on-failure";
      RestartSec = "10s";
      CapabilityBoundingSet = [ "CAP_NET_ADMIN" "CAP_NET_RAW" ];
      AmbientCapabilities = [ "CAP_NET_ADMIN" "CAP_NET_RAW" ];
    };
  };
}
