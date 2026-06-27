{ config, pkgs, ... }:

{
  imports = [
    ../../modules/home/common.nix
  ];

  home.username = "z";
  home.homeDirectory = "/Users/z";

  # CLI tools moved off Homebrew — nixpkgs provides these (jq already comes from
  # modules/home/common.nix). Could be promoted to common.nix later if wanted on
  # the Linux hosts too.
  home.packages = with pkgs; [
    bash
    curl
    f3
    gh
    neovim
    nmap
    unzip
    wget
  ];

  # zsh is the macOS default login shell; let Home Manager manage ~/.zshrc
  # (starship + direnv from common.nix hook into it automatically).
  programs.zsh.enable = true;

  # macOS rebuild aliases (darwin-rebuild, not nixos-rebuild). home.shellAliases
  # applies to zsh and merges with the shared `ll` from common.nix.
  home.shellAliases = {
    drs = "sudo darwin-rebuild switch --flake ~/Code/nixos-config#serenity";
    npull = "git -C ~/Code/nixos-config pull";
  };

  home.stateVersion = "26.05";
}
