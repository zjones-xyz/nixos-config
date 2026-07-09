{ config, pkgs, ... }:

{
  imports = [
    ../../modules/home/interactive-zsh.nix
  ];

  home.username = "z";
  home.homeDirectory = "/home/z";

  home.packages = with pkgs; [
    ripgrep
    fd
    jq
    btop
  ];

  home.shellAliases = {
    ll = "ls -la";
    nrs = "sudo nixos-rebuild switch --flake ~/nixos-config#hopper";
    nrt = "sudo nixos-rebuild test --flake ~/nixos-config#hopper";
    npull = "git -C ~/nixos-config pull";
  };

  programs.git = {
    enable = true;
    settings.user.name = "z";
    settings.user.email = "zoej7@protonmail.com";
  };

  home.stateVersion = "26.05";
}
