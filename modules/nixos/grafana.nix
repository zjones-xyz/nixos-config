{ config, pkgs, lib, ... }:

let
  cfg = config.services.grafana;
  domain = "grafana.monitor.zjones.dev";
  # Not Grafana's default 3000: that's a common default worth keeping free
  # (Bambuddy's virtual printers already claim it on their own address).
  port = 3030;
  secretsDir = "${cfg.dataDir}/secrets";

  # ── Dashboards ──
  # Pinned upstream JSON, not vendored: "Node Exporter Full" is ~470 KB.
  # Copied, not linkFarm'd, so Grafana's file provider never sees a symlink.
  nodeExporterFull = pkgs.fetchurl {
    url = "https://raw.githubusercontent.com/rfmoz/grafana-dashboards/b07d8a90d8fadd112e9ac841b777ee863cda850b/prometheus/node-exporter-full.json";
    hash = "sha256-wueaXq0VU34OvidqKHjJXWKGyhq42yzX9p1LqMB53n4=";
  };
  dashboards = pkgs.runCommand "grafana-dashboards" { } ''
    mkdir $out
    cp ${nodeExporterFull} $out/node-exporter-full.json
  '';
in
{
  services.grafana = {
    enable = true;

    settings = {
      server = {
        # Traefik runs in Docker and reaches this over the trusted br-proxy
        # bridge (traefik.nix), so loopback won't do. The port is NOT opened
        # in the firewall; the LAN can't reach it except through Traefik.
        http_addr = "0.0.0.0";
        http_port = port;
        inherit domain;
        root_url = "https://${domain}/";
      };

      # ── Secrets ──
      # Generated on the host by preStart below, not sops: secret_key only has
      # to be unique and stable, and admin_password is read once, when the DB
      # is first created. memory-alpha DECISIONS.md §4.
      security = {
        admin_password = "$__file{${secretsDir}/admin_password}";
        secret_key = "$__file{${secretsDir}/secret_key}";
        cookie_secure = true;
        disable_gravatar = true;
      };

      analytics = {
        reporting_enabled = false;
        check_for_updates = false;
        check_for_plugin_updates = false;
        feedback_links_enabled = false;
      };
    };

    # ── Provisioning ──
    # Datasource and dashboards are code: UI edits to them are refused, so
    # change them here. Dashboards you build by hand in the UI still persist.
    provision = {
      enable = true;
      datasources.settings = {
        apiVersion = 1;
        datasources = [
          {
            name = "Prometheus";
            type = "prometheus";
            uid = "prometheus";
            url = "http://127.0.0.1:${toString config.services.prometheus.port}";
            isDefault = true;
            editable = false;
            jsonData.timeInterval = config.services.prometheus.globalConfig.scrape_interval;
          }
        ];
      };
      dashboards.settings = {
        apiVersion = 1;
        providers = [
          {
            name = "fleet";
            folder = "Fleet";
            options.path = dashboards;
            disableDeletion = true;
            allowUiUpdates = false;
          }
        ];
      };
    };
  };

  # Runs as `grafana`, before the server reads the $__file{} references above.
  # Never overwrites: the admin password is `sudo cat`'d once after first start.
  systemd.services.grafana.preStart = ''
    install -d -m 0700 ${secretsDir}
    for f in secret_key admin_password; do
      if [ ! -s "${secretsDir}/$f" ]; then
        (umask 077 && ${lib.getExe pkgs.openssl} rand -hex 32 > "${secretsDir}/$f.tmp")
        mv "${secretsDir}/$f.tmp" "${secretsDir}/$f"
      fi
    done
  '';

  homelab.traefik.fileConfigs.grafana = (pkgs.formats.yaml { }).generate "grafana.yml" {
    http = {
      routers.grafana = {
        rule = "Host(`${domain}`)";
        entrypoints = [ "websecure" ];
        # The *.monitor.zjones.dev wildcard is already requested by the
        # dashboard router in traefik.nix; this just reuses it.
        tls.certResolver = "letsencrypt";
        service = "grafana-svc";
      };
      services.grafana-svc.loadBalancer.servers = [
        { url = "http://host.docker.internal:${toString port}"; }
      ];
    };
  };
}
