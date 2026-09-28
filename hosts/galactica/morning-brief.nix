{
  config,
  pkgs,
  lib,
  ...
}:

# Morning brief — the daily HTML page a Claude routine renders, mirrored here
# so the admin dashboard can iframe it (claude.ai refuses to be framed). The
# routine force-pushes brief.html to the private zjones-xyz/morning-brief repo;
# a timer pulls it into stateDir and a static server hands it out.
# MANUAL-STEPS.md §21 has the owner steps (repo, token, sops, routine).

let
  image = "joseluisq/static-web-server:2.44.0";
  stateDir = "/var/lib/morning-brief";
  port = 3027; # next free loopback slot after memos.nix's 3026

  swsConfig = (pkgs.formats.toml { }).generate "morning-brief-sws.toml" {
    general.cache-control-headers = false;
    advanced.headers = [
      {
        source = "**";
        headers = {
          # Refreshed daily under a fixed name — never let a browser keep it.
          Cache-Control = "no-cache";
          # Only the admin dashboard may embed it.
          Content-Security-Policy =
            "frame-ancestors https://home.peacock-koi.ts.net https://home.zjones.dev https://home.internal";
        };
      }
    ];
  };

  fetchScript = pkgs.writeShellApplication {
    name = "morning-brief-fetch";
    runtimeInputs = [ pkgs.curl pkgs.coreutils ];
    text = ''
      tmp=$(mktemp -p ${stateDir} .brief.XXXXXX)
      trap 'rm -f "$tmp"' EXIT
      # Token via --config on stdin, so it never appears in argv.
      printf 'header = "Authorization: Bearer %s"\n' "$(< "$CREDENTIALS_DIRECTORY/token")" |
        curl --config - --fail --silent --show-error --max-time 60 \
          -H "Accept: application/vnd.github.raw+json" \
          -H "X-GitHub-Api-Version: 2022-11-28" \
          -o "$tmp" \
          https://api.github.com/repos/zjones-xyz/morning-brief/contents/brief.html
      chmod 0644 "$tmp"
      mv "$tmp" ${stateDir}/index.html
    '';
  };
in
{
  users.users.morning-brief = {
    isSystemUser = true;
    group = "morning-brief";
  };
  users.groups.morning-brief = { };

  # 0755: the container reads it as whatever uid the image runs as.
  systemd.tmpfiles.rules = [
    "d ${stateDir} 0755 morning-brief morning-brief - -"
  ];

  # Fine-grained PAT, Contents: read-only on zjones-xyz/morning-brief only.
  sops.secrets."morning-brief/githubToken" = { };

  systemd.services.morning-brief-fetch = {
    description = "Pull the morning brief from GitHub";
    wants = [ "network-online.target" ];
    after = [ "network-online.target" ];
    serviceConfig = (import ./service-hardening.nix) // {
      Type = "oneshot";
      User = "morning-brief";
      Group = "morning-brief";
      LoadCredential = "token:${config.sops.secrets."morning-brief/githubToken".path}";
      ReadWritePaths = [ stateDir ];
      ExecStart = lib.getExe fetchScript;
    };
  };

  # The routine runs at 04:30 Pacific and can take a couple of hours; polling
  # every 15 min is well inside GitHub's authenticated rate limit.
  systemd.timers.morning-brief-fetch = {
    description = "Periodic morning brief pull";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "2min";
      OnUnitActiveSec = "15min";
      Unit = "morning-brief-fetch.service";
    };
  };

  # Tailnet only — no Traefik pair and no zjones.dev name. The page carries
  # mail and calendar summaries, and the LAN includes guests' devices.
  virtualisation.oci-containers.containers.morning-brief = {
    inherit image;
    environment.SERVER_CONFIG_FILE = "/etc/sws.toml";
    volumes = [
      "${stateDir}:/public:ro"
      "${swsConfig}:/etc/sws.toml:ro"
    ];
    ports = [ "127.0.0.1:${toString port}:80" ];
    labels = {
      "tsdproxy.enable" = "true";
      "tsdproxy.name" = "brief";
      "tsdproxy.port.1" = "443/https:${toString port}/http";
    };
  };
}
