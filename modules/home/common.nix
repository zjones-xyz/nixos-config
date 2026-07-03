{ config, pkgs, lib, ... }:

# ─────────────────────────────────────────────────────────────────────────────
# Shared Home Manager layer — portable across platforms.
# ─────────────────────────────────────────────────────────────────────────────
# Consumed by BOTH nixosConfigurations.pegasus and darwinConfigurations.<mac>.
# Keep this strictly cross-platform: only prefs that make sense on Linux *and*
# macOS. Anything host- or platform-specific (username, homeDirectory,
# stateVersion, the `nrs`/`nrt` rebuild aliases, Plasma config) stays in the
# per-host home.nix. See hosts/pegasus/DECISIONS.md for what lives where.
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
  programs.starship.enable = true;

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
