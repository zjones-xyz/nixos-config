{ pkgs, ... }:

{
  # Native PipeWire mic noise suppression — a declarative replacement for
  # NoiseTorch (see hosts/pegasus/DECISIONS.md for why NoiseTorch itself was
  # abandoned: it never activates on PipeWire 1.6+, confirmed against
  # upstream noisetorch/NoiseTorch#467/#470/#412, all open/unfixed as of
  # 2026-08). Builds the same RNNoise LADSPA plugin NoiseTorch vendors
  # (`rnnoise-plugin` is werman/noise-suppression-for-voice — NoiseTorch's
  # `c/ladspa` is a vendored copy of this exact project) into a permanent
  # "Noise Canceling source" virtual mic, wired up at PipeWire's native
  # filter-chain level instead of through PipeWire's PulseAudio-compat LADSPA
  # module — no GUI, no per-login relaunch, live as soon as PipeWire starts.
  #
  # Requires services.pipewire.enable (desktop-plasma.nix on hosts that use
  # this).
  services.pipewire.extraLadspaPackages = [ pkgs.rnnoise-plugin.ladspa ];

  services.pipewire.extraConfig.pipewire."99-input-denoising" = {
    "context.modules" = [
      {
        name = "libpipewire-module-filter-chain";
        args = {
          "node.description" = "Noise Canceling source";
          "media.name" = "Noise Canceling source";
          "filter.graph" = {
            nodes = [
              {
                type = "ladspa";
                name = "rnnoise";
                # Resolved via LADSPA_PATH (set automatically from
                # extraLadspaPackages above), not a filesystem path — this is
                # the exact thing NoiseTorch gets wrong on PipeWire 1.6+, see
                # the module comment above.
                plugin = "librnnoise_ladspa";
                label = "noise_suppressor_mono";
                control."VAD Threshold (%)" = 50.0;
              }
            ];
          };
          "capture.props" = {
            "node.name" = "capture.rnnoise_source";
            "node.passive" = true;
            "audio.rate" = 48000;
          };
          "playback.props" = {
            "node.name" = "rnnoise_source";
            "media.class" = "Audio/Source";
            "audio.rate" = 48000;
          };
        };
      }
    ];
  };
}
