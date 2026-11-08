{ config, pkgs, lib, ... }:

# ── Prebuild: build this host's next system before the switch ──
# Polls origin and builds the toplevel of each watched branch, and each ref in
# the `targets` file, that moved: breakage surfaces before merging and `nrs`
# finds it built. prebuild-discover fills `targets` from GitHub; the build only
# reads it. Builds bypass nix-daemon, so this unit's caps apply. docs/PREBUILD.md.
let
  cfg = config.services.prebuild;
  discoverUnit = lib.optional cfg.discover.enable "prebuild-discover.service";

  # targets ref → state key: refs/pull/<N>/head → pr-<N>, anything else ref-<path>.
  keyOf = ''
    key_of() {
      if [[ $1 =~ ^refs/pull/([0-9]+)/head$ ]]; then echo "pr-''${BASH_REMATCH[1]}"
      else r=''${1#refs/}; echo "ref-''${r//\//_}"; fi
    }
  '';

  run = pkgs.writeShellApplication {
    name = "prebuild-run";
    runtimeInputs = [ config.nix.package ] ++ (with pkgs; [ git coreutils gawk gnugrep libnotify util-linux ]);
    text = ''
      state=$STATE_DIRECTORY
      ${keyOf}

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

      # The static branches, then each "<ref>\t<label>" line of targets.
      refs=() keys=() labels=()
      for branch in $BRANCHES; do
        refs+=("refs/heads/$branch") keys+=("''${branch//\//_}") labels+=("$branch")
      done
      if [ -r "$state/targets" ]; then
        while IFS=$'\t' read -r ref label || [ -n "$ref" ]; do
          [[ $ref =~ ^refs/[A-Za-z0-9._/-]+$ ]] || continue # also keeps the URL below intact
          k=$(key_of "$ref")
          case " ''${keys[*]} " in *" $k "*) continue ;; esac
          refs+=("$ref") keys+=("$k") labels+=("''${label:-$ref}")
        done <"$state/targets"
      fi

      # A ref that left targets (PR closed or merged): drop its state and GC root.
      shopt -s nullglob
      for f in "$state"/pr-* "$state"/ref-* "$state"/result-pr-* "$state"/result-ref-*; do
        k=''${f##*/}
        case $k in result-*) k=''${k#result-} ;; *) k=''${k%.*} ;; esac
        case " ''${keys[*]} " in *" $k "*) ;; *) rm -f "$f" ;; esac
      done

      heads=$(git ls-remote "$REPO" "''${refs[@]}")

      rc=0
      for i in "''${!refs[@]}"; do
        ref=''${refs[i]} key=''${keys[i]} label=''${labels[i]}
        sha=$(awk -v r="$ref" '$2 == r { print $1 }' <<<"$heads")
        if [ -z "$sha" ]; then # ref gone (merged bump PR): drop its GC root
          rm -f "$state/$key".{sha,err,log,started} "$state/result-$key"
          continue
        fi
        [ "$(cat "$state/$key.sha" 2>/dev/null)" = "$sha" ] && continue

        short=''${sha:0:7}
        echo "prebuild: $label @ $short"
        if [ "$(cat "$state/$key.started" 2>/dev/null)" != "$sha" ]; then # once per commit, not per retry
          echo "$sha" >"$state/$key.started"
          notify "$HOST prebuild started" "$label @ $short" low
        fi
        if nix build --max-jobs "$MAX_JOBS" --cores "$CORES" --out-link "$state/result-$key" \
            "git+$REPO?ref=$ref&rev=$sha#nixosConfigurations.$HOST.config.system.build.toplevel" \
            2>&1 | tee "$state/$key.log"; then
          echo "$sha" >"$state/$key.sha"
          rm -f "$state/$key.err"
          notify "$HOST prebuild ready" "$label @ $short is built." normal
          continue
        fi

        rc=1
        failed=$(grep -m1 -oP "(Cannot build|fixed-output derivation) '/nix/store/[a-z0-9]{32}-\K[^']+(?=\.drv')" "$state/$key.log" || true)
        if grep -qE 'signal 9|Killed|deadly signal' "$state/$key.log"; then
          # Hit this unit's memory cap: not the package's fault.
          soft_fail "$sha" "$HOST prebuild out of memory" \
            "$label @ $short: ''${failed:-a build} hit the prebuild's $MEMORY_MAX cap. Retrying next run; nrs can build it uncapped."
        elif [ -n "$failed" ]; then
          # A real build failure: don't retry this commit.
          echo "$sha" >"$state/$key.sha"
          rm -f "$state/$key.err" "$state/result-$key"
          notify "$HOST prebuild failed" "$label @ $short: $failed doesn't build. Log: $state/$key.log" critical
        else
          soft_fail "$sha" "$HOST prebuild error" "$label @ $short didn't evaluate or fetch. Log: $state/$key.log"
        fi
      done
      exit "$rc"
    '';
  };

  # Writes targets for the run above, and is the only part that talks to GitHub.
  # Same-repo heads only: a fork's PR would otherwise be built as root.
  discover = pkgs.writeShellApplication {
    name = "prebuild-discover";
    runtimeInputs = with pkgs; [ curl jq coreutils ];
    text = ''
      out=$STATE_DIRECTORY/targets
      tmp=$(mktemp "$out.XXXXXX")
      trap 'rm -f "$tmp"' EXIT
      curl -fsSL --max-time 60 --retry 2 \
        -H 'Accept: application/vnd.github+json' -H 'X-GitHub-Api-Version: 2022-11-28' \
        "https://api.github.com/repos/$SLUG/pulls?state=open&per_page=100" |
        jq -r --arg slug "$SLUG" --argjson scopes "$SCOPES" --argjson skip "$SKIP" --argjson days "$MAX_AGE_DAYS" '
          if type == "array" then .[] else error("unexpected response: \(.)") end
          | select(.head.repo.full_name == $slug and (.head.ref | IN($skip[]) | not))
          | select($days == null or (.updated_at | fromdateiso8601) > now - $days * 86400)
          # Leading scopes: "[pegasus] …", "[pegasus/dashboard] …", "[pegasus, serenity] …"
          | select([.title | (capture("^(?<s>(\\[[^]]*\\]\\s*)+)").s // "")
                    | scan("\\[([^]]*)\\]")[0] | split(",")[]
                    | split("/")[0] | gsub("^\\s+|\\s+$"; "")]
                   | any(IN($scopes[])))
          | "refs/pull/\(.number)/head\t#\(.number) \(.title | gsub("[\\t\\n\\r]"; " "))"
        ' >"$tmp"
      chmod 644 "$tmp"
      mv "$tmp" "$out"
      echo "prebuild-discover: $(wc -l <"$out") matching PR(s)"
    '';
  };

  # The command people type: `prebuild now`, `prebuild status`, `prebuild stop`.
  cli = pkgs.writeShellApplication {
    name = "prebuild";
    runtimeInputs = with pkgs; [ systemd coreutils ];
    text = ''
      state=/var/lib/prebuild
      ${keyOf}
      show() { # key label
        st=$(cat "$state/$1.started" 2>/dev/null || true)
        sh=$(cat "$state/$1.sha" 2>/dev/null || true)
        er=$(cat "$state/$1.err" 2>/dev/null || true)
        if [ -n "$st" ] && [ "$st" != "$sh" ] && [ "$st" != "$er" ]; then s="started ''${st:0:7}, not finished"
        elif [ -n "$er" ]; then s="error at ''${er:0:7}, retrying"
        elif [ -e "$state/result-$1" ]; then s="built ''${sh:0:7}"
        elif [ -n "$sh" ]; then s="FAILED at ''${sh:0:7}"
        else s="nothing yet"; fi
        echo "  $2: $s"
      }
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
            show "''${branch//\//_}" "$branch"
          done
          if [ -r "$state/targets" ]; then
            echo "targets (listed $(date -r "$state/targets" '+%F %R')):"
            while IFS=$'\t' read -r ref label || [ -n "$ref" ]; do
              [[ $ref =~ ^refs/[A-Za-z0-9._/-]+$ ]] || continue
              show "$(key_of "$ref")" "''${label:-$ref}"
            done <"$state/targets"
          fi
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
    discover = {
      enable = lib.mkEnableOption "listing this host's open PRs into the prebuild's targets file before each run";
      slug = lib.mkOption {
        type = lib.types.str;
        default = "zjones-xyz/nixos-config";
        description = "GitHub owner/repo whose open PRs are listed: the repo `repo` points at.";
      };
      scopes = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ cfg.host "all" ];
        defaultText = lib.literalExpression ''[ config.services.prebuild.host "all" ]'';
        description = "PR-title scopes to build, as in `[<scope>] …`, `[<scope>/dns] …` or `[other, <scope>] …`.";
      };
      maxAgeDays = lib.mkOption {
        type = lib.types.nullOr lib.types.ints.positive;
        default = 14;
        description = "Skip PRs not updated in this many days, so a backlog of parked PRs isn't each built and GC-rooted. null lists all.";
      };
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
      description = "Prebuild ${cfg.host}'s system from ${lib.concatStringsSep ", " cfg.branches} and listed targets";
      # wants, not requires: when discovery fails, build the last targets list.
      wants = [ "network-online.target" ] ++ discoverUnit;
      after = [ "network-online.target" ] ++ discoverUnit;
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

    systemd.services.prebuild-discover = lib.mkIf cfg.discover.enable {
      description = "List ${cfg.discover.slug} PRs scoped to ${cfg.host} for the prebuild";
      wants = [ "network-online.target" ];
      after = [ "network-online.target" ];
      environment = {
        SLUG = cfg.discover.slug;
        SCOPES = builtins.toJSON cfg.discover.scopes;
        SKIP = builtins.toJSON cfg.branches; # built anyway, as static branches
        MAX_AGE_DAYS = builtins.toJSON cfg.discover.maxAgeDays;
      };
      serviceConfig = {
        Type = "oneshot";
        ExecStart = lib.getExe discover;
        StateDirectory = "prebuild";
        Slice = "prebuild.slice";
        # Root only to write the root-owned state dir; no capabilities beyond that.
        CapabilityBoundingSet = "";
        NoNewPrivileges = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
        PrivateDevices = true;
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectControlGroups = true;
        RestrictAddressFamilies = [ "AF_UNIX" "AF_INET" "AF_INET6" ];
        RestrictNamespaces = true;
        LockPersonality = true;
        MemoryDenyWriteExecute = true;
        SystemCallArchitectures = "native";
        SystemCallFilter = [ "@system-service" "~@privileged" ];
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
