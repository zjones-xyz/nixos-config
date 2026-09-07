{ ... }:

{
  imports = [
    ../../modules/home/common.nix
  ];

  home.username = "z";
  home.homeDirectory = "/home/z";

  home.shellAliases = {
    nrs = "sudo nixos-rebuild switch --flake ~/nixos-config#galactica";
    nrt = "sudo nixos-rebuild test --flake ~/nixos-config#galactica";
    npull = "~/nixos-config/scripts/npull.sh";
  };

  home.stateVersion = "26.05";
}
