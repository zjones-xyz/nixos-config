{ config, pkgs, lib, ... }:

{
  # ── Mouse configuration tooling ──────────────────────────────────────────────
  # Solaar: Logitech Unifying/Bolt/Lightspeed receiver ecosystem (MX Master,
  # MX Keys, etc.) — battery level, DPI, button remapping. enableGraphical
  # pulls in pkgs.solaar itself; the module also wires up logitech-udev-rules
  # for non-root access (see nixos/modules/hardware/logitech.nix).
  hardware.logitech.wireless = {
    enable = true;
    enableGraphical = true;
  };

  # Piper: GTK frontend for ratbagd (libratbag), the generic Linux gaming-mouse
  # config daemon — DPI/buttons/RGB/polling rate across many vendors
  # (Logitech G-series, Razer, SteelSeries, Corsair), not just Logitech.
  # Genuinely different subsystem from Solaar above (HID++/Unifying protocol
  # vs libratbag's own protocol via a separate D-Bus daemon) — confirmed via
  # nixos/modules/services/hardware/ratbagd.nix, no overlap or conflict.
  services.ratbagd.enable = true;
  environment.systemPackages = [ pkgs.piper ];
}
