{ ... }:

{
  imports = [
    ../../modules/home/common.nix
  ];

  home.username = "z";
  home.homeDirectory = "/home/z";

  home.shellAliases = {
    nrs = "sudo nixos-rebuild switch --flake ~/nixos-config#tower-hv";
    nrt = "sudo nixos-rebuild test --flake ~/nixos-config#tower-hv";
    npull = "git -C ~/nixos-config pull";

    # The three checks worth having one keystroke away while proving passthrough.
    vfio-check = "lspci -nnk | grep -A3 -i '1b21:'";
    unraid = "sudo virsh --connect qemu:///system";
    unraid-console = "sudo virsh --connect qemu:///system console unraid";
  };

  home.stateVersion = "26.05";
}
