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
  ];

  # Prompt.
  programs.starship.enable = true;

  # Per-directory env + fast nix-shell caching.
  programs.direnv = {
    enable = true;
    nix-direnv.enable = true;
  };

  # Shell. bash on both platforms keeps behaviour identical; host home.nix adds
  # the machine-specific rebuild aliases on top of these portable ones.
  programs.bash = {
    enable = true;
    shellAliases = {
      ll = "ls -la";
    };
  };

  # Git identity (portable).
  programs.git = {
    enable = true;
    settings.user.name = "z";
    settings.user.email = "zoej7@protonmail.com";
  };

  # Editor.
  programs.vim = {
    enable = true;
    defaultEditor = true;
  };
}
