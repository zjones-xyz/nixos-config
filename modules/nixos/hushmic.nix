{ config, pkgs, lib, self, ... }:

let
  hushmic = self.inputs.hushmic-nix.packages.${pkgs.stdenv.hostPlatform.system}.hushmic;
in
{
  # ── HushMic ─────────────────────────────────────────────────────────────────
  # Adds a "HushMic" PipeWire source with DPDFNet noise suppression; pick it as
  # the input per app. Mirrors upstream's packaging/systemd/hushmic.service, but
  # with the tray rather than --headless, so it binds to graphical-session.target.
  # Leave the tray's "Start on login" off — a second instance loses the lock.
  environment.systemPackages = [ hushmic ];

  systemd.user.services.hushmic = {
    description = "HushMic noise-suppression virtual microphone";
    documentation = [ "https://github.com/Fovty/hushmic" ];
    after = [ "graphical-session.target" "pipewire.service" "wireplumber.service" ];
    wants = [ "pipewire.service" ];
    partOf = [ "graphical-session.target" ];
    wantedBy = [ "graphical-session.target" ];

    serviceConfig = {
      ExecStart = "${lib.getExe hushmic} --tray";
      # Exits 0 on "already running", so on-failure rather than always.
      Restart = "on-failure";
      RestartSec = 3;
      # Its `pipewire -c` child must outlive the SIGTERM long enough to put
      # the previous default mic back.
      KillMode = "mixed";
      TimeoutStopSec = 10;
      # Upstream's slice: session-critical services, beside the compositor.
      Slice = "session.slice";
    };
  };
}
