{ config, pkgs, ... }:

{
  imports = [
    ../../modules/home/common.nix
  ];

  home.username = "z";
  home.homeDirectory = "/Users/z";

  # macOS rebuild aliases (darwin-rebuild, not nixos-rebuild).
  programs.bash.shellAliases = {
    drs = "darwin-rebuild switch --flake ~/nixos-config#serenity";
    npull = "git -C ~/nixos-config pull";
  };

  home.stateVersion = "26.05";
}
