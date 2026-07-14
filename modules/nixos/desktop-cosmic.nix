{ config, pkgs, lib, ... }:

{
  # ── COSMIC, as a secondary selectable session ───────────────────────────────
  # Deliberately NOT enabling services.displayManager.cosmic-greeter — SDDM
  # (from desktop-plasma.nix) stays the sole display manager and just gets a
  # second "COSMIC" entry in its session list alongside Plasma, since NixOS's
  # desktopManager modules install session files that any active display
  # manager picks up regardless of which one enabled them. Plasma stays the
  # primary DE.
  #
  # Why secondary rather than primary (see hosts/pegasus/DECISIONS.md): as of
  # COSMIC Epoch 1.2.0 (2026-06-30) there's no declarative-config story yet
  # (no plasma-manager equivalent — anything customized lives unmanaged in
  # ~/.config/cosmic/), and VRR/HDR — the reason gamescopeSession was chosen
  # in modules/nixos/gaming.nix — still hasn't landed.
  services.desktopManager.cosmic.enable = true;
}
