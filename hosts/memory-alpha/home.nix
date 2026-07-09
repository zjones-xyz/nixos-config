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
    npull = "git -C ~/nixos-config pull";
  };

  home.stateVersion = "26.05";
}
