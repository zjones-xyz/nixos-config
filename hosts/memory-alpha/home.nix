{ config, pkgs, ... }:

{
  home.username = "z";
  home.homeDirectory = "/home/z";

  home.packages = with pkgs; [
    ripgrep
    fd
    jq
    btop
  ];

  programs.bash = {
    enable = true;
    shellAliases = {
      ll = "ls -la";
      nrs = "sudo nixos-rebuild switch --flake /etc/nixos#memory-alpha";
      nrt = "sudo nixos-rebuild test --flake /etc/nixos#memory-alpha";
    };
  };

  programs.git = {
    enable = true;
    userName = "z";
    userEmail = "zoejonestx91@gmail.com";
  };

  home.stateVersion = "26.05";
}
