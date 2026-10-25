{ config, pkgs, lib, ... }:

let
  # ELD monitor names as PipeWire reports them (`node.nick` on the HDMI
  # sinks). Same panels as niri-settings.nix's monLeft/monRight.
  leftMonitor = "DELL S2722QC";
  rightMonitor = "DELL S2721QS";

  profileSetDir = "${config.services.pipewire.package}/share/alsa-card-profile/mixer/profile-sets";
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

  # ── "Monitor Speakers (L/R)": left channel → left Dell, right → right Dell ──
  # Each Dell plays its channel on both of its speakers. Sinks are matched by
  # monitor name, not node.name: the 4070 hands out PCM slots dynamically.
  # A monitor that's off just drops out; the virtual sink itself never goes
  # away, so it stays the default.
  services.pipewire.extraConfig.pipewire."60-monitor-speakers" = {
    "context.modules" = [{
      name = "libpipewire-module-combine-stream";
      args = {
        "combine.mode" = "sink";
        "node.name" = "monitor_speakers_lr";
        "node.description" = "Monitor Speakers (L/R)";
        "combine.latency-compensate" = true;
        "combine.props"."audio.position" = [ "FL" "FR" ];
        "stream.props"."stream.dont-remix" = true;
        "stream.rules" = [
          {
            matches = [{ "media.class" = "Audio/Sink"; "node.nick" = leftMonitor; }];
            actions.create-stream = {
              "audio.position" = [ "FL" "FR" ];
              "combine.audio.position" = [ "FL" "FL" ];
            };
          }
          {
            matches = [{ "media.class" = "Audio/Sink"; "node.nick" = rightMonitor; }];
            actions.create-stream = {
              "audio.position" = [ "FL" "FR" ];
              "combine.audio.position" = [ "FR" "FR" ];
            };
          }
        ];
      };
    }];
  };
}
