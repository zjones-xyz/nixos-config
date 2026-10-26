{ config, pkgs, lib, ... }:

let
  # ELD monitor names as PipeWire reports them (`node.nick` on the HDMI
  # sinks). Same panels as niri-settings.nix's monLeft/monCentre/monRight.
  leftMonitor = "DELL S2722QC";
  centreMonitor = "LG HDR 4K";
  rightMonitor = "DELL S2721QS";

  profileSetDir = "${config.services.pipewire.package}/share/alsa-card-profile/mixer/profile-sets";

  fcUpmix."stream.properties" = {
    "channelmix.upmix" = true;
    "channelmix.upmix-method" = "psd";
    "channelmix.fc-cutoff" = 12000.0;
  };

  # One combine-stream sink. `feeds` maps a monitor to the two combine
  # channels its left and right speakers play.
  monitorSink = { name, description, positions, feeds }: {
    name = "libpipewire-module-combine-stream";
    args = {
      "combine.mode" = "sink";
      "node.name" = name;
      "node.description" = description;
      "combine.latency-compensate" = true;
      "combine.props"."audio.position" = positions;
      "stream.props"."stream.dont-remix" = true;
      "stream.rules" = lib.mapAttrsToList (monitor: channels: {
        matches = [{ "media.class" = "Audio/Sink"; "node.nick" = monitor; }];
        actions.create-stream = {
          "audio.position" = [ "FL" "FR" ];
          "combine.audio.position" = channels;
        };
      }) feeds;
    };
  };
in
{
  # ── 4070 HDMI/DP audio: every monitor as its own sink ───────────────────────
  # Stock profiles open one HDMI PCM at a time. This adds one that opens all
  # four, ranked above the stock ones so WirePlumber picks it, and re-picks it
  # when a monitor comes back. See DECISIONS.md (monitor speakers).
  environment.etc."alsa-card-profile/mixer/profile-sets/pegasus-hdmi-all.conf".text = ''
    .include ${profileSetDir}/default.conf

    [Profile output:hdmi-all]
    description = All monitors
    output-mappings = hdmi-stereo hdmi-stereo-extra1 hdmi-stereo-extra2 hdmi-stereo-extra3
    priority = 10000
  '';

  services.pipewire.wireplumber.extraConfig."60-pegasus-hdmi-all" = {
    "monitor.alsa.rules" = [{
      matches = [{ "device.name" = "alsa_card.pci-0000_2b_00.1"; }];
      actions.update-props."device.profile-set" = "pegasus-hdmi-all.conf";
    }];
  };

  # ── Virtual outputs across the monitor speakers ─────────────────────────────
  # Each Dell plays its side on both of its speakers. Sinks are matched by
  # monitor name, not node.name: the 4070 hands out PCM slots dynamically.
  # A monitor that's off just drops out; the virtual sinks never go away.
  # The two centre variants are on trial; keep one (DECISIONS.md).
  services.pipewire.extraConfig.pipewire."60-monitor-speakers" = {
    "context.modules" = [
      (monitorSink {
        name = "monitor_speakers_lr";
        description = "Monitor Speakers (L/R)";
        positions = [ "FL" "FR" ];
        feeds = {
          ${leftMonitor} = [ "FL" "FL" ];
          ${rightMonitor} = [ "FR" "FR" ];
        };
      })
      # The LG plays the plain stereo mix between the two Dells.
      (monitorSink {
        name = "monitor_speakers_lr_fill";
        description = "Monitor Speakers (L/R + centre fill)";
        positions = [ "FL" "FR" ];
        feeds = {
          ${leftMonitor} = [ "FL" "FL" ];
          ${centreMonitor} = [ "FL" "FR" ];
          ${rightMonitor} = [ "FR" "FR" ];
        };
      })
      # True 3.0: the LG plays FC only. Stereo sources get an FC from the
      # upmix enabled below.
      (monitorSink {
        name = "monitor_speakers_lcr";
        description = "Monitor Speakers (3.0 L/C/R)";
        positions = [ "FL" "FR" "FC" ];
        feeds = {
          ${leftMonitor} = [ "FL" "FL" ];
          ${centreMonitor} = [ "FC" "FC" ];
          ${rightMonitor} = [ "FR" "FR" ];
        };
      })
    ];
  };

  # ── Stereo → FC upmix, for the 3.0 sink ─────────────────────────────────────
  # Off in audioconvert unless set (the defaults in client.conf are commented
  # out). It runs in each app's stream, so it's set for every client. It only
  # acts when a sink has channels the source lacks; no LFE is synthesised.
  services.pipewire.extraConfig.client."60-fc-upmix" = fcUpmix;
  services.pipewire.extraConfig.pipewire-pulse."60-fc-upmix" = fcUpmix;
}
