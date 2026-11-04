{ config, pkgs, lib, self, ... }:

let
  umbrielPkgs = self.inputs.nixpkgs-umbriel.legacyPackages.${pkgs.stdenv.hostPlatform.system};
in
{
  # ── Umbriel, as a selectable SDDM session ───────────────────────────────────
  # Wired by hand from nixpkgs-unstable's programs.umbriel, whose module can't
  # be imported into 26.05 (docs/NIXPKGS-APPS.md). The polkit, dconf and portal
  # base that module adds already comes from programs.niri on this host.
  environment.systemPackages = [ umbrielPkgs.umbriel ];
  environment.pathsToLink = [ "/share/umbriel/effects" ];
  services.displayManager.sessionPackages = [ umbrielPkgs.umbriel ];
  systemd.packages = [ umbrielPkgs.umbriel ];

  # A switch from inside the session must not kill the compositor.
  # path: any NixOS override also sets a coreutils-only PATH, which keybinds
  # and autostart inherit ("noctalia: command not found") unless cleared.
  systemd.user.services.umbriel = {
    restartIfChanged = false;
    path = lib.mkForce [ ];
  };

  xdg.portal = {
    extraPortals = [ umbrielPkgs.xdg-desktop-portal-umbriel ];
    configPackages = [ umbrielPkgs.xdg-desktop-portal-umbriel ];
  };
}
