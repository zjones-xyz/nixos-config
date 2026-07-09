{ pkgs, ... }:

# Shared by the NixOS hosts (hamilton, hopper, memory-alpha). Keeps
# users.users.z.shell = pkgs.bash (modules/nixos/common.nix) as the login
# shell, so non-interactive invocations — `ssh z@host cmd`, most notably —
# get predictable bash semantics. Interactive sessions exec into zsh below,
# to match Serenity's default shell. The `case $- in *i*)` guard is what
# keeps this interactive-only: bash's own .bash_profile/.bashrc split
# already excludes plain `ssh host cmd`, but a login-yet-non-interactive
# invocation (e.g. `sudo -u z -i -- cmd`) can still source this file, so the
# guard is load-bearing, not defensive filler.
{
  programs.bash = {
    enable = true;
    initExtra = ''
      case $- in
        *i*)
          export SHELL="${pkgs.zsh}/bin/zsh"
          exec "$SHELL"
          ;;
      esac
    '';
  };

  programs.zsh.enable = true;
}
