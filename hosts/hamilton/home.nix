{ ... }:

{
  imports = [
    ../../modules/home/common.nix
  ];

  home.username = "z";
  home.homeDirectory = "/home/z";

  home.shellAliases = {
    # Scripts, not bare `sudo nixos-rebuild …` aliases — the alias built
    # whatever was checked out without ever naming the branch.
    nrs = "~/nixos-config/scripts/nrebuild.sh nixos-rebuild switch hamilton";
    nrt = "~/nixos-config/scripts/nrebuild.sh nixos-rebuild test hamilton";
    npull = "~/nixos-config/scripts/npull.sh";
    # A script, not "npull && nrs" — an alias would put the PR number on nrs.
    npullnrs = "~/nixos-config/scripts/npull-rebuild.sh nixos-rebuild hamilton";
  };

  home.stateVersion = "26.05";
}
