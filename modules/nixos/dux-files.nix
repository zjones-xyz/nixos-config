{ config, pkgs, lib, ... }:

{
  # ── Dux Files — the Dux suite's file manager ────────────────────────────────
  # Comes from its own flake (nixosModules.dux-files, wired in flake.nix), like
  # Dux Shell. Kept running with the session so windows open instantly; the
  # folder/"show in folder" defaults are per-user, in hosts/pegasus/home.nix.
  # Open/save dialogs deliberately stay with Nautilus — see DECISIONS.md.
  programs.dux-files = {
    enable = true;
    systemd.enable = true;
  };

  # The daemon serves every window and launches apps from bare desktop-entry
  # Execs; upstream's path = [ quickshell ] replaces the session PATH with a
  # minimal one. Inherit the user manager's PATH instead, as Dux Shell does.
  systemd.user.services.dfiles = {
    path = lib.mkForce [ ];
  };
}
