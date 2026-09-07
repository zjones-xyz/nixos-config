{ config, pkgs, lib, ... }:

{
  # ── Niri, as a fourth selectable SDDM session ───────────────────────────────
  # Scrollable-tiling Wayland compositor, evaluated alongside Plasma/COSMIC/
  # Dragonized rather than replacing any of them — same "additive session"
  # pattern as desktop-cosmic.nix. SDDM (desktop-plasma.nix) stays the sole
  # display manager, but as of 2026-09-01 defaultSession points at this
  # module's session ("niri", nixpkgs' niri package's declared
  # passthru.providedSessions value) — Plasma/COSMIC/Dragonized remain
  # selectable from the picker, just no longer pre-selected. The
  # `programs.niri` module registers its own session file (via
  # services.displayManager.sessionPackages), so — unlike Dragonized —
  # there's no hand-rolled session/wrapper script needed here.
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

  # ── DankMaterialShell — the actual bar/launcher/notification-center/etc ─────
  # community comparison (chosen over Noctalia, 2026-08-11 — see
  # DECISIONS.md): more feature-complete, and this host is going multi-monitor
  # soon, which is Noctalia's one documented weak spot in the field reports
  # that were checked.
  #
  # Uses DankMaterialShell's `nixosModules.dank-material-shell` (NixOS-level,
  # not the home-manager one) — deliberately, to match how every other
  # desktop-*.nix module on this host is wired (Plasma/COSMIC/Dragonized are
  # all NixOS-level, none of them home-manager-level), and because DMS's
  # home-manager module needs a `programs.quickshell` HM option this repo
  # doesn't otherwise pull in, while the NixOS module just installs packages
  # + a systemd --user service directly — no extra option surface needed.
  # Quickshell itself (the QML shell engine DMS is built on) is already in
  # nixpkgs 26.05 at 0.3.0, meeting DMS's stated "at least 0.3.0" minimum, so
  # no separate quickshell flake input was needed — see flake.nix.
  programs.dank-material-shell = {
    enable = true;
    # Binds dms.service to graphical-session.target, which niri's own
    # packaged systemd units activate on session start — no manual
    # spawn-at-startup entry needed for DMS to come up automatically on
    # login (unlike a plain compositor-native systemd integration, this is
    # DMS's own supported path, see distro/nix/nixos.nix upstream).
    systemd.enable = true;
    # enableVPN/enableDynamicTheming/enableAudioWavelength/enableCalendarEvents
    # all default true and just add small, unexciting deps (networkmanager
    # glue, matugen, cava, khal) — left at upstream defaults rather than
    # trimmed, nothing here conflicts with anything else on this host.
  };

  # ── Declarative niri config.kdl, added 2026-08-11 ──────────────────────────
  # hosts/pegasus/niri-settings.nix (imported via home.nix) declares
  # programs.niri.settings, using niri-flake's homeModules.config — but
  # deliberately ONLY that module, not niri-flake's nixosModules.niri (which
  # would disable the programs.niri.enable line above and install
  # niri-flake's own from-source niri build instead of nixpkgs'). See
  # flake.nix's niri-flake input comment and DECISIONS.md for the full
  # reasoning, including a real divergence risk niri-flake's own README
  # flags for this exact combination (nixpkgs' niri + niri-flake's config
  # schema) — the short version is: check niri-flake's changelog before
  # assuming a build failure here is a mistake in niri-settings.nix.
  #
  # Also deliberately NOT using DMS's own `homeModules.niri` keybind-
  # injection module — despite niri-flake now being in use, that module
  # additionally needs DMS's `homeModules.dank-material-shell` imported at
  # the home-manager level too (for its own `cfg.enable` reference to
  # resolve), which would reintroduce the `programs.quickshell` HM-option
  # exposure this file avoids by using DMS's NixOS module above. DMS's
  # keybinds are hand-transcribed directly into niri-settings.nix's `binds`
  # instead — see that file for the full list and the handful of key
  # conflicts (Mod+Comma, Mod+V, the media keys) that had to be resolved
  # between niri's own suggested defaults and what DMS wanted.
}
