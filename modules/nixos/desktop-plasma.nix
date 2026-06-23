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
