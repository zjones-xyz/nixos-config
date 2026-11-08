{ config, pkgs, lib, ... }:

# ── Prebuild: build this host's next system before the switch ──
# Polls origin and builds the toplevel of each watched branch that moved, so a
# broken bump surfaces before merging and `nrs` afterwards finds it built.
# Builds bypass nix-daemon so they run in this unit's own cgroup, hard-capped
# and idle, where a kill costs a retry and not the desktop. docs/PREBUILD.md.
let
  cfg = config.services.prebuild;

  run = pkgs.writeShellApplication {
    name = "prebuild-run";
    runtimeInputs = [ config.nix.package ] ++ (with pkgs; [ git coreutils gnugrep libnotify util-linux ]);
    text = ''
      state=$STATE_DIRECTORY

      notify() { # summary body urgency
        [ -n "$NOTIFY_USER" ] || return 0
        uid=$(id -u "$NOTIFY_USER")
        [ -S "/run/user/$uid/bus" ] || return 0 # not logged in
        runuser -u "$NOTIFY_USER" -- env DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$uid/bus" \
          notify-send -a prebuild -u "$3" "$1" "$2" || true
      }

      # Retried next run, but notified once per commit.
      soft_fail() { # sha summary body
        [ "$(cat "$state/$key.err" 2>/dev/null)" = "$1" ] && return 0
        echo "$1" >"$state/$key.err"
        notify "$2" "$3" normal
      }

      rc=0
      for branch in $BRANCHES; do
        key=''${branch//\//_}
        sha=$(git ls-remote "$REPO" "refs/heads/$branch" | cut -f1)
        if [ -z "$sha" ]; then # branch gone (merged bump PR): drop its GC root
          rm -f "$state/$key".{sha,err,log,started} "$state/result-$key"
          continue
        fi
        [ "$(cat "$state/$key.sha" 2>/dev/null)" = "$sha" ] && continue

        short=''${sha:0:7}
        echo "prebuild: $branch @ $short"
        if [ "$(cat "$state/$key.started" 2>/dev/null)" != "$sha" ]; then # once per commit, not per retry
          echo "$sha" >"$state/$key.started"
          notify "$HOST prebuild started" "$branch @ $short" low
        fi
        if nix build --max-jobs "$MAX_JOBS" --cores "$CORES" --out-link "$state/result-$key" \
            "git+$REPO?ref=$branch&rev=$sha#nixosConfigurations.$HOST.config.system.build.toplevel" \
            2>&1 | tee "$state/$key.log"; then
          echo "$sha" >"$state/$key.sha"
          rm -f "$state/$key.err"
          notify "$HOST prebuild ready" "$branch @ $short is built." normal
          continue
        fi

        rc=1
        failed=$(grep -m1 -oP "(Cannot build|fixed-output derivation) '/nix/store/[a-z0-9]{32}-\K[^']+(?=\.drv')" "$state/$key.log" || true)
        if grep -qE 'signal 9|Killed|deadly signal' "$state/$key.log"; then
          # Hit this unit's memory cap: not the package's fault.
          soft_fail "$sha" "$HOST prebuild out of memory" \
            "$branch @ $short: ''${failed:-a build} hit the prebuild's $MEMORY_MAX cap. Retrying next run; nrs can build it uncapped."
        elif [ -n "$failed" ]; then
          # A real build failure: don't retry this commit.
          echo "$sha" >"$state/$key.sha"
          rm -f "$state/$key.err" "$state/result-$key"
          notify "$HOST prebuild failed" "$branch @ $short: $failed doesn't build. Log: $state/$key.log" critical
        else
          soft_fail "$sha" "$HOST prebuild error" "$branch @ $short didn't evaluate or fetch. Log: $state/$key.log"
        fi
      done
      exit "$rc"
    '';
  };

  # The command people type: `prebuild now`, `prebuild status`, `prebuild stop`.
  cli = pkgs.writeShellApplication {
    name = "prebuild";
    runtimeInputs = with pkgs; [ systemd coreutils ];
    text = ''
      state=/var/lib/prebuild
      case "''${1:-status}" in
        now)
          sudo systemctl start --no-block prebuild.service
          echo "prebuild started; 'prebuild status' to check, 'prebuild stop' to cancel."
          if [ "''${2:-}" = "-f" ]; then exec journalctl -fu prebuild.service -n 0 -o cat; fi
          ;;
        stop) sudo systemctl stop prebuild.service ;;
        status)
          echo "service: $(systemctl is-active prebuild.service || true)," \
            "next check: $(systemctl show prebuild.timer -p NextElapseUSecRealtime --value)"
          for branch in ${lib.escapeShellArgs cfg.branches}; do
            key=''${branch//\//_}
            st=$(cat "$state/$key.started" 2>/dev/null || true)
            sh=$(cat "$state/$key.sha" 2>/dev/null || true)
            er=$(cat "$state/$key.err" 2>/dev/null || true)
            if [ -n "$st" ] && [ "$st" != "$sh" ] && [ "$st" != "$er" ]; then s="started ''${st:0:7}, not finished"
            elif [ -n "$er" ]; then s="error at ''${er:0:7}, retrying"
            elif [ -e "$state/result-$key" ]; then s="built ''${sh:0:7}"
            elif [ -n "$sh" ]; then s="FAILED at ''${sh:0:7}"
            else s="nothing yet"; fi
            echo "  $branch: $s"
          done
          ;;
        *) echo "usage: prebuild [now [-f] | status | stop]" >&2; exit 2 ;;
      esac
    '';
  };
in
{
  options.services.prebuild = {
    enable = lib.mkEnableOption "background builds of this host's system from the repo's watched branches";
    host = lib.mkOption {
      type = lib.types.str;
      default = config.networking.hostName;
      description = "Attribute under nixosConfigurations to build.";
    };
    repo = lib.mkOption {
      type = lib.types.str;
      default = "https://github.com/zjones-xyz/nixos-config";
      description = "Git URL of the fleet repo.";
    };
    branches = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      # bump-app-inputs: the scheduled lane bump's PR branch (update-apps.yml).
      default = [ "bump-app-inputs" "main" ];
      description = "Branches to build when they move. A missing branch is skipped.";
    };
    notifyUser = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "User whose desktop session gets the result notifications.";
    };
    interval = lib.mkOption {
      type = lib.types.str;
      default = "hourly";
      description = "systemd OnCalendar expression for the poll.";
    };
    memoryHigh = lib.mkOption {
      type = lib.types.str;
      default = "12G";
      description = "Where the prebuild starts being throttled and reclaimed, below memoryMax.";
    };
    memoryMax = lib.mkOption {
      type = lib.types.str;
      default = "16G";
      description = "Hard memory cap for the whole prebuild (eval plus builds). Past it, a compiler is OOM-killed and the run retries later.";
    };
    maxJobs = lib.mkOption {
      type = lib.types.int;
      default = 2;
      description = "Derivations built at once.";
    };
    cores = lib.mkOption {
      type = lib.types.int;
      default = 4;
      description = "Threads per derivation build.";
    };
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [ cli ];

    # Root-level, so cpu.idle ranks it against user.slice and not just other
    # services (pegasus DECISIONS.md, "nix-daemon builds run at batch priority").
    systemd.slices.prebuild.sliceConfig = {
      CPUWeight = "idle";
      IOWeight = 10;
    };

    systemd.services.prebuild = {
      description = "Prebuild ${cfg.host}'s system from ${lib.concatStringsSep ", " cfg.branches}";
      wants = [ "network-online.target" ];
      after = [ "network-online.target" ];
      environment = {
        HOST = cfg.host;
        REPO = cfg.repo;
        BRANCHES = lib.concatStringsSep " " cfg.branches;
        NOTIFY_USER = if cfg.notifyUser == null then "" else cfg.notifyUser;
        MAX_JOBS = toString cfg.maxJobs;
        CORES = toString cfg.cores;
        MEMORY_MAX = cfg.memoryMax;
        # Build in this process tree, not nix-daemon's, so the limits below
        # cover the compilers. Root may use the store directly.
        NIX_REMOTE = "local";
      };
      serviceConfig = {
        Type = "oneshot";
        ExecStart = lib.getExe run;
        StateDirectory = "prebuild";
        Slice = "prebuild.slice";
        Nice = 19;
        IOSchedulingClass = "idle";
        # Hard caps: a kill here fails a retryable background build, not a
        # switch. MemorySwapMax keeps it from growing on in zram.
        MemoryHigh = cfg.memoryHigh;
        MemoryMax = cfg.memoryMax;
        MemorySwapMax = "2G";
        # First to go under global memory pressure.
        OOMScoreAdjust = 1000;
        ManagedOOMMemoryPressure = "kill";
        ManagedOOMMemoryPressureLimit = "50%";
      };
    };

    systemd.timers.prebuild = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = cfg.interval;
        OnBootSec = "15min";
        Persistent = true;
        RandomizedDelaySec = "10min";
      };
    };
  };
}
