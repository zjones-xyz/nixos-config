{ config, pkgs, lib, ... }:

let
  user = "z";
  pw = config.services.pipewire;
  hasHushmic = config.systemd.user.services ? hushmic;

  userUnits = [ "pipewire.service" "wireplumber.service" ]
    ++ lib.optional pw.pulse.enable "pipewire-pulse.service"
    ++ lib.optional hasHushmic "hushmic.service";

  avSelftest = pkgs.writeShellApplication {
    name = "av-selftest";
    runtimeInputs = [
      pw.package
      pw.wireplumber.package
      pkgs.pulseaudio # pactl: browsers reach the mic through pipewire-pulse
      pkgs.jq
      pkgs.coreutils
      pkgs.systemd
    ];
    text = ''
      XDG_RUNTIME_DIR="/run/user/$(id -u)"
      DBUS_SESSION_BUS_ADDRESS="unix:path=$XDG_RUNTIME_DIR/bus"
      export XDG_RUNTIME_DIR DBUS_SESSION_BUS_ADDRESS

      if ! systemctl --user is-active --quiet graphical-session.target 2>/dev/null; then
        echo "no graphical session for $(id -un); skipped"
        exit 0
      fi

      captures() { # [target] → true if 1 s of recording delivers any audio
        # --raw: the default container writes a header even when nothing flows.
        [ "$( (timeout 1 pw-record --raw ''${1:+--target "$1"} - 2>/dev/null || true) | wc -c)" -gt 0 ]
      }

      has_node() { # jq condition on a node's props
        jq -e "any(.[]; .info.props? // {} | $1)" <<<"$graph" >/dev/null
      }

      run_checks() {
        failures=()
        for u in ${lib.escapeShellArgs userUnits}; do
          systemctl --user is-active --quiet "$u" || failures+=("user unit $u is $(systemctl --user is-active "$u" || true)")
        done
        graph=$(pw-dump 2>/dev/null || echo '[]')
        wpctl inspect @DEFAULT_AUDIO_SINK@ >/dev/null 2>&1 || failures+=("no default audio output")
        wpctl inspect @DEFAULT_AUDIO_SOURCE@ >/dev/null 2>&1 || failures+=("no default microphone")
        captures || failures+=("no audio from the default microphone")
        ${lib.optionalString pw.pulse.enable ''
          pactl get-default-source >/dev/null 2>&1 || failures+=("PulseAudio (pipewire-pulse) not answering")
        ''}
        ${lib.optionalString hasHushmic ''
          # pw-record falls back to the default mic for a missing target, so check the node first.
          if has_node '."node.name" == "hushmic_source"'; then
            captures hushmic_source || failures+=("no audio from the HushMic source")
          else
            failures+=("HushMic source missing")
          fi
        ''}
        cams=(/dev/v4l/by-id/*-video-index0)
        [ -e "''${cams[0]}" ] || failures+=("no webcam under /dev/v4l/by-id")
        has_node '."media.class" == "Video/Source"' || failures+=("PipeWire exposes no camera (Video/Source)")
      }

      # The switch has just restarted the audio units; give them time to settle.
      for _ in $(seq 6); do
        run_checks
        [ ''${#failures[@]} -eq 0 ] && { echo "audio and webcam OK"; exit 0; }
        sleep 2
      done

      echo "audio/webcam self-test FAILED:"
      printf '  - %s\n' "''${failures[@]}"
      echo "Usual fix: systemctl --user restart ${lib.concatStringsSep " " userUnits}"
      exit 1
    '';
  };
in
{
  # ── Audio/webcam self-test ──────────────────────────────────────────────────
  # A switch can leave the PipeWire stack running but broken (e.g. a removed and
  # re-added user unit is never started again). This runs on every switch,
  # ordered before sysinit-reactivation.target, the one unit every switch
  # restarts; if it fails, the switch ends with its "units failed" warning.
  environment.systemPackages = [ avSelftest ];

  systemd.services.av-selftest = {
    description = "Audio and webcam self-test after a switch";
    wantedBy = [ "sysinit-reactivation.target" ];
    before = [ "sysinit-reactivation.target" ];
    restartIfChanged = false;
    serviceConfig = {
      Type = "oneshot";
      User = user;
      ExecStart = lib.getExe avSelftest;
      TimeoutStartSec = 60;
    };
  };
}
