{ config, pkgs, ... }:

{
  imports = [
    ../../modules/home/common.nix
  ];

  home.username = "z";
  home.homeDirectory = "/home/z";

  # Host-specific rebuild aliases (layered on top of the shared portable ones
  # from modules/home/common.nix's home.shellAliases).
  programs.bash.enable = true;
  programs.bash.shellAliases = {
    nrs = "sudo nixos-rebuild switch --flake ~/nixos-config#pegasus";
    nrt = "sudo nixos-rebuild test --flake ~/nixos-config#pegasus";
    npull = "git -C ~/nixos-config pull";
  };

  # ── Declarative Plasma 6 (plasma-manager) ───────────────────────────────────
  # plasma-manager's HM module is wired in via home-manager.sharedModules in
  # flake.nix. This is a minimal starting point — Plasma writes a lot of state,
  # so grow this incrementally (export current settings with `plasma-manager`'s
  # rc2nix). See hosts/pegasus/DECISIONS.md.
  programs.plasma = {
    enable = true;
    workspace.lookAndFeel = "org.kde.breezedark.desktop";
  };

  home.stateVersion = "26.05";
}
