{ config, pkgs, lib, ... }:

{
  # ── KDE Plasma 6 on Wayland, SDDM login ─────────────────────────────────────
  # Wayland is the default session; SDDM itself runs on Wayland too. On NVIDIA
  # this pairs with modesetting.enable = true (set in nvidia.nix), which is
  # required for a working Wayland session.
  services.displayManager.sddm = {
    enable = true;
    wayland.enable = true;
  };
  services.desktopManager.plasma6.enable = true;

  # Pre-selects Dragonized in SDDM's session chooser — "plasma-dragonized" is
  # dragonizedSessionFile's declared providedSessions value (see
  # desktop-dragonized.nix), the only valid value for this option since it's
  # checked directly against every session package's providedSessions list.
  services.displayManager.defaultSession = "plasma-dragonized";

  # Audio: PipeWire is the modern default for a desktop.
  services.pulseaudio.enable = false;
  security.rtkit.enable = true;
  services.pipewire = {
    enable = true;
    alsa.enable = true;
    alsa.support32Bit = true;
    pulse.enable = true;
  };
}
