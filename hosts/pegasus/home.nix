{ config, pkgs, ... }:

# NOTE: Phase 5 refactors this to consume the shared modules/home/common.nix and
# adds plasma-manager for declarative Plasma. Kept self-contained for now.
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
      nrs = "sudo nixos-rebuild switch --flake ~/nixos-config#pegasus";
      nrt = "sudo nixos-rebuild test --flake ~/nixos-config#pegasus";
      npull = "git -C ~/nixos-config pull";
    };
  };

  programs.git = {
    enable = true;
    settings.user.name = "z";
    settings.user.email = "zoej7@protonmail.com";
  };

  home.stateVersion = "26.05";
}
