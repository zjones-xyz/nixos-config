{ config, pkgs, ... }:

{
  imports = [
    ../../modules/home/common.nix
  ];

  home.username = "z";
  home.homeDirectory = "/Users/z";

  # zsh is the macOS default login shell; let Home Manager manage ~/.zshrc
  # (starship + direnv from common.nix hook into it automatically).
  programs.zsh.enable = true;

  # macOS rebuild aliases (darwin-rebuild, not nixos-rebuild). home.shellAliases
  # applies to zsh and merges with the shared `ll` from common.nix.
  home.shellAliases = {
    drs = "darwin-rebuild switch --flake ~/nixos-config#serenity";
    npull = "git -C ~/nixos-config pull";
  };

  home.stateVersion = "26.05";
}
