{ config, pkgs, lib, ... }:

# ─────────────────────────────────────────────────────────────────────────────
# Shared Home Manager layer — portable across platforms.
# ─────────────────────────────────────────────────────────────────────────────
# Consumed by every host: nixosConfigurations.{hamilton,hopper,memory-alpha}
# and darwinConfigurations.serenity. Keep this strictly cross-platform: only
# prefs that make sense on Linux *and* macOS. Anything host- or
# platform-specific (username, homeDirectory, stateVersion, the `nrs`/`nrt`/
# `npull` rebuild aliases, extra packages) stays in the per-host home.nix.
{
  # Core CLI tooling.
  home.packages = with pkgs; [
    ripgrep
    fd
    jq
    btop
    micro
  ];

  # Prompt.
  programs.starship = {
    enable = true;
    settings = {
      # Only show the hostname over SSH (matches starship's own default —
      # made explicit here so it doesn't silently change on a starship
      # upgrade), so the local prompt on each host stays uncluttered while
      # an SSH'd-in session still tells you which box you're on.
      hostname = {
        ssh_only = true;
        format = "[$hostname]($style) ";
        style = "bold dimmed green";
      };

      # Only show command duration for commands that actually take a while,
      # so quick commands don't clutter the prompt with a "took 12ms".
      cmd_duration = {
        min_time = 3000;
        format = "took [$duration]($style) ";
        style = "bold yellow";
      };
    };
  };

  # Per-directory env + fast nix-shell caching.
  programs.direnv = {
    enable = true;
    nix-direnv.enable = true;
  };

  # Shell-agnostic aliases — applied to whichever shell each host enables (bash
  # on the Linux hosts, zsh on the Mac). Shell choice itself is per-host, so this
  # module does not enable a shell; each home.nix does.
  home.shellAliases = {
    ll = "ls -la";
  };

  # zsh leaves INTERACTIVE_COMMENTS off outside sh/ksh emulation, so a `#` at
  # an interactive prompt is an ordinary character and the shell tries to run
  # the "comment" as arguments. Turning it on makes pasted/annotated commands
  # behave the way they do in bash. Set here rather than in a host home.nix so
  # every zsh in the fleet matches; it is inert on hosts that never enable zsh.
  #
  # Trade-off, accepted: an unquoted `#` that *starts a word* now begins a
  # comment, so `echo done #1` prints "done". Mid-word `#` is unaffected
  # (URL fragments, `git show HEAD#…`, `${var#prefix}` all still work).
  programs.zsh.initContent = ''
    setopt interactive_comments
  '';

  # Git identity (portable).
  programs.git = {
    enable = true;
    settings.user.name = "z";
    settings.user.email = "zoej7@protonmail.com";
  };

  # Editor — micro as default; vim kept as fallback.
  home.sessionVariables = {
    EDITOR = "micro";
    VISUAL = "micro";
  };

  programs.vim.enable = true;
}
