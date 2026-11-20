# Fleet monitoring

What watches the fleet, and where it's heading. Why the metrics stack lives
where it does: `hosts/memory-alpha/DECISIONS.md` §4.

## Today

| Tool | Where | Role |
|---|---|---|
| Beszel | memory-alpha (homelab-stacks), agents on hosts | At-a-glance host and container stats |
| Scrutiny | memory-alpha (homelab-stacks) | Disk SMART history |
| Uptime Kuma | memory-alpha (homelab-stacks) | Is the URL up |
| ntfy | memory-alpha (homelab-stacks) | Push notifications |
| **Prometheus** | memory-alpha (native, `modules/nixos/prometheus.nix`) | Metrics store; the thing alerts will come from |
| **Grafana** | memory-alpha (native, `modules/nixos/grafana.nix`), `grafana.monitor.zjones.dev` | Dashboards over Prometheus |

Prometheus and Grafana are deliberately overkill for a homelab this size.
They're here to learn the stack most observability roles assume.

## Roadmap

One PR per phase, each switchable on its own.

1. **Pipeline on one host** (done): Prometheus and Grafana on memory-alpha,
   scraping memory-alpha's own node exporter. Grafana provisioned with the
   datasource and the "Node Exporter Full" dashboard.
2. **Every NixOS host exports.** `prometheus-node.nix` grows a listener
   reachable from memory-alpha only, on the tailnet interface: exporters
   have no auth. Then come the per-host exporters:
   - galactica: `smartctl`, `nut`, `exportarr`, ZFS (node exporter's own
     collector), and Traefik's built-in `/metrics`.
   - memory-alpha: `smartctl`, cAdvisor, Traefik metrics.
   - pegasus: `nvidia-gpu`.
3. **Alerting.** Alertmanager → ntfy. First rules: target down, disk or pool
   filling, ZFS pool degraded, SMART failing, UPS on battery, a systemd unit
   failed. `promtool test rules` unit tests as a `checks/prometheus-rules`
   flake check, built in CI.
4. **Stretch.** Blackbox exporter probing our own URLs (Uptime Kuma,
   Prometheus-style), recording rules and SLO burn-rate alerts, and Loki +
   Alloy for logs.

Whether Beszel, Scrutiny or Uptime Kuma retire once their Prometheus
equivalents exist is a later decision, recorded where it's made.
