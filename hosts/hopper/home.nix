{ ... }:

{
  imports = [
    ../../modules/home/common.nix
  ];

  home.username = "z";
  home.homeDirectory = "/home/z";

  home.shellAliases = {
    nrs = "sudo nixos-rebuild switch --flake ~/nixos-config#hopper";
    nrt = "sudo nixos-rebuild test --flake ~/nixos-config#hopper";
    npull = "~/nixos-config/scripts/npull.sh";
    # A script, not "npull && nrs" — an alias would put the PR number on nrs.
    npullnrs = "~/nixos-config/scripts/npull-rebuild.sh nixos-rebuild hopper";
  };

  home.stateVersion = "26.05";
}
