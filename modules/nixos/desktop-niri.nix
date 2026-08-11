{ config, pkgs, lib, ... }:

{
  # ── Niri, as a fourth selectable SDDM session ───────────────────────────────
  # Scrollable-tiling Wayland compositor, evaluated alongside Plasma/COSMIC/
  # Dragonized rather than replacing any of them — same "additive session"
  # pattern as desktop-cosmic.nix. SDDM (desktop-plasma.nix) stays the sole
  # display manager and defaultSession stays "plasma-dragonized"; this just
  # adds "Niri" to the session picker. The `programs.niri` module registers
  # its own session file (via services.displayManager.sessionPackages), so —
  # unlike Dragonized — there's no hand-rolled session/wrapper script needed
  # here.
  #
  # NVIDIA fit: explicit sync (the thing that fixes flicker/stutter on NVIDIA
  # Wayland) needs driver >=555 and kernel >=6.8 — both already satisfied by
  # this host (modules/nixos/nvidia.nix's production channel, and
  # boot.kernelPackages = linuxPackages_latest in configuration.nix). Niri
  # uses smithay, not wlroots, so none of the WLR_*-style NVIDIA workarounds
  # apply. One known quirk: the driver doesn't release VRAM properly under
  # niri (idles around ~1 GiB instead of ~100 MiB) — cosmetic, not addressed
  # here; see https://github.com/niri-wm/niri/wiki/Nvidia if it becomes a
  # real problem.
  programs.niri.enable = true;

  # Niri has no built-in Xwayland (unlike Plasma/COSMIC's KWin/Mutter, which
  # bundle X11 app support). It integrates xwayland-satellite automatically
  # once the binary is on PATH — no further wiring needed. Required for the
  # X11-only apps already in this host's daily use (Discord, some Steam
  # titles, Bambu Studio/OpenSCAD) to appear at all under a Niri session.
  environment.systemPackages = [ pkgs.xwayland-satellite ];

  # Portal config, Xwayland omission, gnome-keyring default, and the Nautilus
  # dbus-service wiring for the FileChooser portal are all handled by
  # `programs.niri` itself (nixpkgs' module already implements upstream's
  # recommended https://github.com/YaLTeR/niri/wiki/Important-Software#portals
  # setup) — deliberately not overridden here. Plasma's own KDE portal
  # registers under a separate xdg.portal.config key (matched at runtime by
  # $XDG_CURRENT_DESKTOP), so the two coexist without conflict.
}
