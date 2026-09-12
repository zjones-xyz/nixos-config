{ config, pkgs, lib, ... }:

# ─────────────────────────────────────────────────────────────────────────────
# Shared Home Manager layer — portable across platforms.
# ─────────────────────────────────────────────────────────────────────────────
# Consumed by every host's home.nix, Linux and darwin alike. Keep this
# strictly cross-platform: only
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
    gh
    hyfetch

    # Here as well as modules/nixos/common.nix because this module is the only
    # one serenity (darwin) shares — nixos/common.nix reaches the six NixOS
    # hosts, this reaches the Mac too. `jq` above is the same story, predating
    # the split.
    openssl
  ];

  # ── Terminal theme: Catppuccin Mocha ────────────────────────────────────────
  # Colors live here (fleet-wide) so any host's terminal picks up the same
  # palette. alacritty is enabled fleet-wide (replaces the plain package
  # above — programs.alacritty pulls it in itself); kitty is only *themed*
  # here, not enabled — enabling stays per-host (e.g. hosts/pegasus/home.nix,
  # which also owns installing the kitty package — see niri-settings.nix).
  programs.alacritty = {
    enable = true;
    settings.colors = {
      primary = {
        background = "#1e1e2e";
        foreground = "#cdd6f4";
      };
      cursor = {
        text = "#1e1e2e";
        cursor = "#f5e0dc";
      };
      normal = {
        black = "#45475a";
        red = "#f38ba8";
        green = "#a6e3a1";
        yellow = "#f9e2af";
        blue = "#89b4fa";
        magenta = "#f5c2e7";
        cyan = "#94e2d5";
        white = "#bac2de";
      };
      bright = {
        black = "#585b70";
        red = "#f38ba8";
        green = "#a6e3a1";
        yellow = "#f9e2af";
        blue = "#89b4fa";
        magenta = "#f5c2e7";
        cyan = "#94e2d5";
        white = "#a6adc8";
      };
    };
  };

  programs.kitty.settings = {
    background = "#1e1e2e";
    foreground = "#cdd6f4";
    selection_background = "#f5e0dc";
    selection_foreground = "#1e1e2e";
    cursor = "#f5e0dc";
    cursor_text_color = "#1e1e2e";

    color0 = "#45475a";
    color8 = "#585b70";
    color1 = "#f38ba8";
    color9 = "#f38ba8";
    color2 = "#a6e3a1";
    color10 = "#a6e3a1";
    color3 = "#f9e2af";
    color11 = "#f9e2af";
    color4 = "#89b4fa";
    color12 = "#89b4fa";
    color5 = "#f5c2e7";
    color13 = "#f5c2e7";
    color6 = "#94e2d5";
    color14 = "#94e2d5";
    color7 = "#bac2de";
    color15 = "#a6adc8";
  };

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
