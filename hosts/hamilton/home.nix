{ ... }:

{
  imports = [
    ../../modules/home/common.nix
  ];

  home.username = "z";
  home.homeDirectory = "/home/z";

  home.shellAliases = {
    nrs = "sudo nixos-rebuild switch --flake ~/nixos-config#hamilton";
    nrt = "sudo nixos-rebuild test --flake ~/nixos-config#hamilton";
    npull = "git -C ~/nixos-config pull";
  };

  home.stateVersion = "26.05";
}
