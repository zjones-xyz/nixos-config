{ config, pkgs, ... }:

{
  home.username = "z";
  home.homeDirectory = "/home/z";

  home.packages = with pkgs; [
    ripgrep
    fd
    jq
    btop
  ];

  # Login/non-interactive shell stays bash (users.users.z.shell in
  # modules/nixos/common.nix), so `ssh z@memory-alpha cmd`, cron, and systemd
  # services keep predictable bash semantics — none of those source .bashrc,
  # since sshd invokes `bash -c cmd` non-interactively for them. Interactive
  # sessions exec into zsh below, to match Serenity's default shell.
  programs.bash = {
    enable = true;
    initExtra = ''
      case $- in
        *i*)
          if [ -z "$ZSH_VERSION" ] && command -v zsh >/dev/null 2>&1; then
            export SHELL="$(command -v zsh)"
            exec zsh
          fi
          ;;
      esac
    '';
  };

  programs.zsh.enable = true;

  home.shellAliases = {
    ll = "ls -la";
    nrs = "sudo nixos-rebuild switch --flake ~/nixos-config#memory-alpha";
    nrt = "sudo nixos-rebuild test --flake ~/nixos-config#memory-alpha";
    npull = "git -C ~/nixos-config pull";
  };

  programs.git = {
    enable = true;
    settings.user.name = "z";
    settings.user.email = "zoej7@protonmail.com";
  };

  home.stateVersion = "26.05";
}
