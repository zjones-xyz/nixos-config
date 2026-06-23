{ config, pkgs, lib, ... }:

let
  # ── Olla — local-first LLM proxy with health-check failover ─────────────────
  # Olla (https://github.com/thushan/olla) is a single Go binary that fronts
  # multiple OpenAI/Ollama-compatible endpoints and load-balances with health
  # checks. It is not in nixpkgs, so we build it here.
  #
  # PLACEHOLDER HASHES: `version`, `src.hash`, and `vendorHash` below are stubs
  # (lib.fakeHash). The closure EVALUATES with them, but BUILDING olla will fail
  # until they are filled in with real values. This is a MANUAL step — see
  # hosts/pegasus/MANUAL-STEPS.md for the one-liner to obtain them.
  olla = pkgs.buildGoModule rec {
    pname = "olla";
    version = "0.0.0"; # PLACEHOLDER — set to a real released tag
    src = pkgs.fetchFromGitHub {
      owner = "thushan";
      repo = "olla";
      rev = "v${version}";
      hash = lib.fakeHash; # PLACEHOLDER
    };
    vendorHash = lib.fakeHash; # PLACEHOLDER
    # Most Olla releases embed version via ldflags; harmless if ignored.
    ldflags = [ "-s" "-w" ];
    meta = {
      description = "Local-first LLM proxy with health-check failover";
      homepage = "https://github.com/thushan/olla";
      mainProgram = "olla";
    };
  };

  # Olla configuration. SCHEMA IS ILLUSTRATIVE — verify against Olla's current
  # docs before relying on it (see hosts/pegasus/DECISIONS.md). Two upstreams:
  #   - pegasus's own ollama on localhost (drained automatically while gaming)
  #   - the separate dual-GTX-1070 Ollama node, reached over Tailscale
  ollaConfig = pkgs.writeText "olla.yaml" ''
    server:
      host: "0.0.0.0"        # tailnet-only in practice (firewall trusts tailscale0)
      port: 40114

    # Health checks drain an endpoint from the pool when it is down — this is
    # what makes the pegasus gaming-window pause "just work": when ollama is
    # stopped, pegasus fails its health check and traffic routes to the 1070 node.
    discovery:
      type: static
      static:
        endpoints:
          - name: pegasus-4070
            url: "http://127.0.0.1:11434"
            type: ollama
            priority: 100          # prefer the faster Ada card
            health_check:
              path: "/api/tags"
              interval: 10s
          - name: gpu1070-node      # PLACEHOLDER hostname — the Pascal box
            url: "http://gpu1070.internal:11434"
            type: ollama
            priority: 50
            health_check:
              path: "/api/tags"
              interval: 10s
  '';
in
{
  # Run Olla as an unprivileged dynamic user.
  systemd.services.olla = {
    description = "Olla LLM router (fronts pegasus + the 1070 node)";
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      ExecStart = "${lib.getExe olla} --config ${ollaConfig}";
      DynamicUser = true;
      Restart = "on-failure";
      RestartSec = "5s";
    };
  };

  # Tailnet-only exposure: pegasus's firewall trusts tailscale0 (set in the host
  # config), so :40114 is reachable over the tailnet and blocked on the LAN. No
  # extra allowedTCPPorts rule is added on purpose.

  # ── Overnight batch (placeholder) ───────────────────────────────────────────
  # A nightly window to run batch inference against the router. The script is a
  # STUB for Zoe to fill in (what to run). It does not change global suspend
  # behaviour — if the box sleeps, schedule an rtcwake the evening before, or set
  # the BIOS RTC wake; see hosts/pegasus/MANUAL-STEPS.md.
  systemd.services.ollama-batch = {
    description = "Overnight batch inference (stub)";
    after = [ "olla.service" ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = pkgs.writeShellScript "ollama-batch" ''
        echo "TODO: feed batch jobs to http://127.0.0.1:40114 here" >&2
        exit 0
      '';
    };
  };

  systemd.timers.ollama-batch = {
    description = "Run overnight batch inference at 02:00";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "*-*-* 02:00:00";
      Persistent = true;
    };
  };
}
