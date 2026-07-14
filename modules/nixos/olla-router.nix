{ config, pkgs, lib, ... }:

let
  # ── Olla — local-first LLM proxy with health-check failover ─────────────────
  # Olla (https://github.com/thushan/olla) is a single Go binary that fronts
  # multiple OpenAI/Ollama-compatible endpoints and load-balances with health
  # checks. It is not in nixpkgs, so we build it here.
  #
  # `version`, `src.hash`, and `vendorHash` are all REAL now (pinned to olla
  # v0.0.28; `src.hash` resolved 2026-07-03 via `nix-prefetch-github thushan
  # olla --rev v0.0.28`; `vendorHash` resolved 2026-07-11 from the real
  # x86_64-linux build on pegasus — buildGoModule can only compute it from a
  # build that runs on the package's own system, which the authoring session
  # (aarch64-darwin, no Linux builder) couldn't do). To bump the version
  # later: change `version`, re-run nix-prefetch-github for the new `hash`,
  # then a fakeHash build cycle for `vendorHash`.
  olla = pkgs.buildGoModule rec {
    pname = "olla";
    version = "0.0.28";
    src = pkgs.fetchFromGitHub {
      owner = "thushan";
      repo = "olla";
      rev = "v${version}";
      hash = "sha256-/nXMEs50kixi8j/1oyaYnMB9Rju7gCbsY85m06NK8As=";
    };
    vendorHash = "sha256-6RjPRUwneF1lPMpomqJNKt86duDIZFwBoN79ioeApPM=";
    # Most Olla releases embed version via ldflags; harmless if ignored.
    ldflags = [ "-s" "-w" ];
    meta = {
      description = "Local-first LLM proxy with health-check failover";
      homepage = "https://github.com/thushan/olla";
      mainProgram = "olla";
    };
  };

  # Olla configuration — schema verified against olla v0.0.28's shipped
  # config/config.yaml and internal/config/types.go (2026-07-03). Olla starts
  # from DefaultConfig() and overlays this file, so a partial config is safe:
  # anything omitted keeps Olla's built-in default. We override only what pegasus
  # needs. Two upstreams:
  #   - pegasus's own ollama on localhost (drained automatically while gaming)
  #   - the separate dual-GTX-1070 Ollama node, reached over Tailscale
  ollaConfig = pkgs.writeText "olla.yaml" ''
    server:
      host: "0.0.0.0"        # tailnet-only in practice (firewall trusts tailscale0)
      port: 40114            # default, but pinned here to match the firewall note

    # priority (not the default least-connections) is what makes the failover
    # design work: Olla always routes to the highest-priority *healthy* endpoint.
    # So all traffic hits the 4070 while it's up, and only spills to the 1070
    # when the 4070's health check fails — which is exactly what happens when the
    # gaming-window pause stops ollama (see modules/nixos/ollama.nix).
    proxy:
      load_balancer: "priority"

    discovery:
      type: "static"
      static:
        endpoints:
          - name: "pegasus-4070"
            url: "http://127.0.0.1:11434"
            type: "ollama"
            priority: 100          # prefer the faster Ada card
            model_url: "/api/tags"
            health_check_url: "/"
            check_interval: 5s
            check_timeout: 2s
          - name: "gpu1070-node"    # PLACEHOLDER hostname — the Pascal box
            url: "http://gpu1070.internal:11434"
            type: "ollama"
            priority: 50
            model_url: "/api/tags"
            health_check_url: "/"
            check_interval: 5s
            check_timeout: 2s
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
