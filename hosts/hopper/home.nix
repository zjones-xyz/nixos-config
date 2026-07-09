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
    npull = "git -C ~/nixos-config pull";
  };

  home.stateVersion = "26.05";
}
