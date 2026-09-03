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
    # Edit this host's own sops secrets using its SSH host key as the age
    # identity, without needing serenity's admin key. The host key is a
    # recipient of secrets/galactica.yaml (its ssh-to-age matches &galactica in
    # .sops.yaml), but it's root-only and — importantly — sops's built-in
    # SOPS_AGE_SSH_PRIVATE_KEY_FILE path does NOT convert the ed25519 key on
    # this sops build (verified 2026-09-03: it read the key, derived no usable
    # identity, and fell through). So convert it ourselves with `ssh-to-age
    # -private-key` (the same thing sops-nix does at boot) and hand sops the age
    # secret via SOPS_AGE_KEY, in-process under sudo so nothing hits disk.
    # EDITOR is forwarded through since sudo resets the environment. Usage is
    # identical to plain sops, e.g. `sops-hostkey secrets/galactica.yaml`.
    sops-hostkey = ''sudo env EDITOR="$EDITOR" bash -c 'SOPS_AGE_KEY=$(ssh-to-age -private-key < /etc/ssh/ssh_host_ed25519_key) sops "$@"' sops-hostkey'';
  };

  home.stateVersion = "26.05";
}
