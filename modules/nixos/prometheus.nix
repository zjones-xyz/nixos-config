{ config, pkgs, lib, ... }:

# ── Prometheus server ─────────────────────────────────────────────────────────
# The fleet's metrics store, native rather than a homelab-stacks compose stack
# so scrape config and (later) alert rules are reviewed Nix. Loopback-only: its
# one client is Grafana on the same host. For the raw UI, tunnel it:
#   ssh -L 9090:127.0.0.1:9090 z@memory-alpha.internal
# Why here and not galactica: memory-alpha DECISIONS.md §4.
let
  nodeExporter = config.services.prometheus.exporters.node;
in
{
  services.prometheus = {
    enable = true;
    listenAddress = "127.0.0.1";
    # A handful of hosts' worth of series is a few GB at most at this length.
    retentionTime = "90d";

    globalConfig = {
      scrape_interval = "30s";
      evaluation_interval = "30s";
    };

    scrapeConfigs = [
      {
        job_name = "prometheus";
        static_configs = [
          { targets = [ "127.0.0.1:${toString config.services.prometheus.port}" ]; }
        ];
      }
      {
        job_name = "node";
        # `instance` is the host name, not 127.0.0.1:9100, so dashboards and
        # alerts read the same once remote hosts are scraped by address.
        static_configs = [
          {
            targets = [ "127.0.0.1:${toString nodeExporter.port}" ];
            labels.instance = config.networking.hostName;
          }
        ];
      }
    ];
  };
}
