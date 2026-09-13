{ ... }:

{
  imports = [
    ../../modules/home/common.nix
  ];

  home.username = "z";
  home.homeDirectory = "/home/z";

  home.shellAliases = {
    nrs = "sudo nixos-rebuild switch --flake ~/nixos-config#memory-alpha";
    nrt = "sudo nixos-rebuild test --flake ~/nixos-config#memory-alpha";
    npull = "~/nixos-config/scripts/npull.sh";
    # A script, not "npull && nrs" — an alias would put the PR number on nrs.
    npullnrs = "~/nixos-config/scripts/npull-rebuild.sh nixos-rebuild memory-alpha";
  };

  home.stateVersion = "26.05";
}
