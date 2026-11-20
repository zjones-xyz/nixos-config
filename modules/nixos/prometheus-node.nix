{ config, pkgs, lib, ... }:

# ── Prometheus node exporter ──────────────────────────────────────────────────
# Host metrics (CPU, memory, disks, network, filesystems) for the fleet
# Prometheus on memory-alpha (modules/nixos/prometheus.nix). The `systemd`
# collector adds per-unit state, so "a unit failed" becomes alertable.
# Loopback-only while memory-alpha is the only scrape target; other hosts
# need a tailnet-scoped listener before they can import this.
{
  services.prometheus.exporters.node = {
    enable = true;
    listenAddress = "127.0.0.1";
    enabledCollectors = [ "systemd" ];
  };
}
