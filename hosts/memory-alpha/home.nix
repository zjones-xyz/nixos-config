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
      npull = "git -C ~/nixos-config pull";
    };
  };

  programs.git = {
    enable = true;
    user.name = "z";
    user.email = "zoejonestx91@gmail.com";
  };

  home.stateVersion = "26.05";
}
