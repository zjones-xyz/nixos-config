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
    runtimeInputs = [ config.nix.package ] ++ (with pkgs; [ git coreutils gawk gnugrep jq libnotify util-linux ]);
    text = ''
      state=$STATE_DIRECTORY

      # The kernel's count of OOM kills in this unit's own cgroup: whether
      # MemoryMax killed a compiler, whatever that compiler's parent printed.
      cg=/sys/fs/cgroup$(sed -n 's/^0:://p' /proc/self/cgroup)
      oom_kills() { awk '$1 == "oom_kill" { print $2 }' "$cg/memory.events" 2>/dev/null || true; }

      # A build thrashing at MemoryMax can stall for hours without an OOM
      # kill. Once the cgroup's "full" memory stall (PSI total, µs) reaches
      # STALL_PCT% of the last STALL_MIN minutes, stop nix and call it an OOM.
      full_stall() { awk '$1 == "full" { sub("total=", "", $5); print $5 }' "$cg/memory.pressure" 2>/dev/null || echo 0; }
      stall_watch() {
        local -a t=()
        while sleep 60; do
          t+=("$(full_stall)")
          (( ''${#t[@]} > STALL_MIN )) || continue
          if (( t[-1] - t[0] >= STALL_MIN * 60 * 10000 * STALL_PCT )); then
            touch "$state/stalled"
            kill -TERM "$(cat "$state/build.pid")" # nix stops its builders
            return 0
          fi
          t=("''${t[@]:1}")
        done
      }

      notify() { # summary body urgency
        [ -n "$NOTIFY_USER" ] || return 0
        uid=$(id -u "$NOTIFY_USER")
        [ -S "/run/user/$uid/bus" ] || return 0 # not logged in
        runuser -u "$NOTIFY_USER" -- env DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$uid/bus" \
          notify-send -a prebuild -u "$3" "$1" "$2" || true
      }

      # A fixed-output (fetcher) derivation: it failing means a download failed.
      is_fod() {
        nix derivation show "$1" 2>/dev/null \
          | jq -e '[(.derivations // .)[] | .outputs[] | .hash? // empty] | length > 0' >/dev/null
      }

      # Retried next run, but notified once per commit.
      soft_fail() { # sha summary body
        [ "$(cat "$state/$key.err" 2>/dev/null)" = "$1" ] && return 0
        echo "$1" >"$state/$key.err"
        notify "$2" "$3" normal
      }

      # One ls-remote for every branch. Unreachable origin: notify once, retry.
      read -ra watched <<<"$BRANCHES"
      if ! heads=$(git ls-remote "$REPO" "''${watched[@]/#/refs/heads/}"); then
        [ -e "$state/remote.err" ] || notify "$HOST prebuild error" "Can't reach $REPO; retrying next run." normal
        touch "$state/remote.err"
        exit 1
      fi
      rm -f "$state/remote.err"

      rc=0
      for branch in "''${watched[@]}"; do
        key=''${branch//\//_}
        sha=$(awk -v r="refs/heads/$branch" '$2 == r { print $1 }' <<<"$heads")
        if [ -z "$sha" ]; then # branch gone (merged bump PR): drop its GC root
          rm -f "$state/$key".{sha,err,log,attempt} "$state/result-$key"
          continue
        fi
        [ "$(cat "$state/$key.sha" 2>/dev/null)" = "$sha" ] && continue

        short=''${sha:0:7}
        log=$state/$key.log
        echo "prebuild: $branch @ $short" | tee "$log"

        # Evaluate in its own process so its ~2.4 GB heap is freed before the
        # compilers start under the same MemoryMax.
        if ! drv=$(nix eval --raw \
            "git+$REPO?ref=$branch&rev=$sha#nixosConfigurations.$HOST.config.system.build.toplevel.drvPath" \
            2> >(tee -a "$log" >&2)); then
          rc=1
          soft_fail "$sha" "$HOST prebuild error" "$branch @ $short didn't evaluate or fetch. Log: $log"
          continue
        fi

        # After an OOM kill or a memory stall, retry at once with less
        # parallelism; only a second one is reported. Nobody waits on this
        # build, so slower is fine.
        attempt=$state/$key.attempt # the last attempt's output, judged below
        for jobs in "$MAX_JOBS:$CORES" "$LOW_JOBS:$LOW_CORES"; do
          result=fail
          kills=$(oom_kills)
          rm -f "$state/stalled" "$state/build.pid"
          stall_watch &
          watcher=$!
          # exec: the group's PID becomes nix's, for stall_watch to interrupt.
          if { echo "$BASHPID" >"$state/build.pid"
               exec nix build --max-jobs "''${jobs%:*}" --cores "''${jobs#*:}" \
                 --out-link "$state/result-$key" "$drv^*"; } 2>&1 | tee "$attempt"; then
            result=ok
          fi
          kill "$watcher" 2>/dev/null || true
          wait "$watcher" 2>/dev/null || true
          cat "$attempt" >>"$log"
          [ "$result" = fail ] || break
          if [ -e "$state/stalled" ]; then why="memory stall"
          elif [ "$(oom_kills)" != "$kills" ]; then why=OOM
          else break; fi
          result=oom
          echo "prebuild: $why at ''${jobs%:*} jobs x ''${jobs#*:} cores" | tee -a "$log"
        done

        if [ "$result" = ok ]; then
          echo "$sha" >"$state/$key.sha"
          rm -f "$state/$key.err"
          case " $QUIET_BRANCHES " in
            *" $branch "*) ;; # result in `prebuild status`; failures still notify
            *) notify "$HOST prebuild ready" "$branch @ $short is built." normal ;;
          esac
          continue
        fi

        rc=1
        # nix names the leaf failure first.
        failed=$(grep -m1 -oP "(Cannot build|fixed-output derivation) '\K/nix/store/[^']+\.drv(?=')" "$attempt" || true)
        name=$(basename "''${failed:-/x-unknown}" .drv | cut -d- -f2-)
        if [ "$result" = oom ]; then
          soft_fail "$sha" "$HOST prebuild out of memory" \
            "$branch @ $short: $name didn't fit in $MEMORY_MAX even at $LOW_JOBS x $LOW_CORES. Retrying next run; nrs can build it uncapped."
        elif ! grep -q 'hash mismatch in fixed-output' "$attempt" \
            && { grep -qE '^error: (unable to download|cannot download)' "$attempt" \
                 || { [ -n "$failed" ] && is_fod "$failed"; }; }; then
          # A download that failed (nix's own fetch, or a fetcher derivation),
          # rather than one that arrived wrong: retry.
          soft_fail "$sha" "$HOST prebuild error" "$branch @ $short: a download''${failed:+ for $name} failed. Retrying next run. Log: $log"
        elif [ -n "$failed" ]; then
          # A real build failure: don't retry this commit. Its old result goes
          # too, so `prebuild status` never shows a stale "built".
          echo "$sha" >"$state/$key.sha"
          rm -f "$state/$key.err" "$state/result-$key"
          notify "$HOST prebuild failed" "$branch @ $short: $name doesn't build. Log: $log" critical
        else
          soft_fail "$sha" "$HOST prebuild error" "$branch @ $short failed to build. Log: $log"
        fi
      done
      exit "$rc"
    '';
  };

  # The command people type: `prebuild now`, `prebuild status`, `prebuild stop`.
  cli = pkgs.writeShellApplication {
    name = "prebuild";
    runtimeInputs = with pkgs; [ systemd coreutils gnused ];
    text = ''
      state=/var/lib/prebuild
      case "''${1:-status}" in
        now)
          # Cursor first, so -f shows the run from its first line.
          cursor=$(journalctl -u prebuild.service -n 0 --show-cursor | sed -n 's/^-- cursor: //p')
          sudo systemctl start --no-block prebuild.service
          echo "prebuild started; 'prebuild status' to check, 'prebuild stop' to cancel."
          if [ "''${2:-}" = "-f" ]; then
            exec journalctl -fu prebuild.service ''${cursor:+--after-cursor="$cursor"} -o cat
          fi
          ;;
        stop) sudo systemctl stop prebuild.service ;;
        status)
          echo "service: $(systemctl is-active prebuild.service || true)," \
            "next check: $(systemctl show prebuild.timer -p NextElapseUSecRealtime --value)"
          if [ -e "$state/remote.err" ]; then echo "  origin unreachable on the last run"; fi
          for branch in ${lib.escapeShellArgs cfg.branches}; do
            key=''${branch//\//_}
            if [ -e "$state/$key.err" ]; then s="error at $(cut -c1-7 "$state/$key.err"), retrying"
            elif [ -e "$state/result-$key" ]; then s="built $(cut -c1-7 "$state/$key.sha")"
            elif [ -e "$state/$key.sha" ]; then s="FAILED at $(cut -c1-7 "$state/$key.sha")"
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
    quietBranches = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      # main moves on every merge, docs included; its result is in `prebuild status`.
      default = [ "main" ];
      description = "Branches whose successful builds don't notify. Failures always do.";
    };
    memoryMax = lib.mkOption {
      type = lib.types.str;
      default = "16G";
      description = "Hard memory cap for the whole prebuild (eval plus builds). Past it, a compiler is OOM-killed and the run retries later.";
    };
    lowMemory = {
      maxJobs = lib.mkOption {
        type = lib.types.int;
        default = 1;
        description = "Derivations built at once when retrying a commit whose build hit memoryMax or stalled on memory.";
      };
      cores = lib.mkOption {
        type = lib.types.int;
        default = 2;
        description = "Threads per derivation build in that retry.";
      };
    };
    memoryStall = {
      percent = lib.mkOption {
        type = lib.types.ints.between 1 100;
        default = 5;
        description = "Share of time the whole cgroup is stalled on memory (PSI \"full\") that counts as an OOM, held for memoryStall.minutes.";
      };
      minutes = lib.mkOption {
        type = lib.types.ints.positive;
        default = 30;
        description = "Window over which memoryStall.percent is measured.";
      };
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
      # A switch must not restart a running prebuild and then wait for it
      # (nixpkgs does the same for nix-gc and auto-upgrade).
      restartIfChanged = false;
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
        LOW_JOBS = toString cfg.lowMemory.maxJobs;
        LOW_CORES = toString cfg.lowMemory.cores;
        MEMORY_MAX = cfg.memoryMax;
        STALL_PCT = toString cfg.memoryStall.percent;
        STALL_MIN = toString cfg.memoryStall.minutes;
        QUIET_BRANCHES = lib.concatStringsSep " " cfg.quietBranches;
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
        # switch. MemorySwapMax keeps it from growing on in zram. No MemoryHigh:
        # it throttles without ever killing, so the OOM retry never fired
        # (pegasus DECISIONS.md). No oomd: it would kill the script too.
        MemoryMax = cfg.memoryMax;
        MemorySwapMax = "2G";
        OOMScoreAdjust = 1000; # first to go under global memory pressure
        # A MemoryMax kill takes the compiler only; the script lives to report it.
        OOMPolicy = "continue";
      };
    };

    systemd.timers.prebuild = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = cfg.interval;
        OnBootSec = "15min"; # no Persistent: it would fire at boot regardless
        RandomizedDelaySec = "10min";
      };
    };
  };
}
