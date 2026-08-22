{ pkgs, ... }:

{
  imports = [
    ../../modules/home/common.nix
  ];

  home.username = "z";
  home.homeDirectory = "/home/z";

  # gh — npull's PR-number argument shells out to `gh pr checkout`.
  home.packages = with pkgs; [
    gh
  ];

  home.shellAliases = {
    nrs = "sudo nixos-rebuild switch --flake ~/nixos-config#memory-alpha";
    nrt = "sudo nixos-rebuild test --flake ~/nixos-config#memory-alpha";
    npull = "~/nixos-config/scripts/npull.sh";
  };

  home.stateVersion = "26.05";
}
