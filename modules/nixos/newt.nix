{ config, pkgs, lib, ... }:

let
  cfg = config.homelab.newt;
in
{
  # Newt — Pangolin tunnel agent. Persistent outbound tunnel to the Pangolin
  # VPS so public-facing services on this host are reachable without opening
  # inbound ports. Runs as a bare systemd service (not Docker) so it's up
  # before containers start — which also means Pangolin resource targets for
  # this host must be host-resolvable addresses (`localhost:<port>`, never a
  # Docker container name; contrast Tower's old containerized Newt, where
  # container names did resolve).
  options.homelab.newt = {
    enable = lib.mkEnableOption "the Pangolin Newt tunnel agent";

    id = lib.mkOption {
      type = lib.types.str;
      example = "n83mhpnryi0lrid";
      description = ''
        Site ID issued by the Pangolin server when the Site (connector) for
        this host is created. Per host — never reuse another host's. The
        matching client secret goes in this host's sops file as
        `newt/clientSecret`.
      '';
    };

    endpoint = lib.mkOption {
      type = lib.types.str;
      default = "https://pangolin.zjones.xyz";
      description = "Pangolin server the tunnel dials out to.";
    };
  };

  config = lib.mkIf cfg.enable {
    sops.secrets."newt/clientSecret" = {};

    systemd.services.newt = {
      description = "Pangolin Newt tunnel agent";
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      wantedBy = [ "multi-user.target" ];

      # Shell script so we can read the sops-decrypted secret at runtime
      script = ''
        exec ${pkgs.fosrl-newt}/bin/newt \
          --id ${cfg.id} \
          --secret "$(cat ${config.sops.secrets."newt/clientSecret".path})" \
          --endpoint ${cfg.endpoint}
      '';

      serviceConfig = {
        Restart = "on-failure";
        RestartSec = "10s";
        CapabilityBoundingSet = [ "CAP_NET_ADMIN" "CAP_NET_RAW" ];
        AmbientCapabilities = [ "CAP_NET_ADMIN" "CAP_NET_RAW" ];
      };
    };
  };
}
