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

  # ── Terminal theme: Kanagawa (Wave) ─────────────────────────────────────────
  # Colors live here (fleet-wide) so any host's terminal picks up the same
  # palette. alacritty is enabled fleet-wide (replaces the plain package
  # above — programs.alacritty pulls it in itself); kitty is only *themed*
  # here, not enabled — enabling stays per-host (e.g. hosts/pegasus/home.nix,
  # which also owns installing the kitty package — see niri-settings.nix).
  programs.alacritty = {
    enable = true;
    settings.colors = {
      primary = {
        background = "#1f1f28";
        foreground = "#dcd7ba";
      };
      cursor = {
        text = "#1f1f28";
        cursor = "#dcd7ba";
      };
      selection = {
        background = "#2d4f67";
        text = "#dcd7ba";
      };
      normal = {
        black = "#16161d";
        red = "#c34043";
        green = "#76946a";
        yellow = "#c0a36e";
        blue = "#7e9cd8";
        magenta = "#957fb8";
        cyan = "#6a9589";
        white = "#c8c093";
      };
      bright = {
        black = "#727169";
        red = "#e82424";
        green = "#98bb6c";
        yellow = "#e6c384";
        blue = "#7fb4ca";
        magenta = "#938aa9";
        cyan = "#7aa89f";
        white = "#dcd7ba";
      };
    };
  };

  programs.kitty.settings = {
    background = "#1f1f28";
    foreground = "#dcd7ba";
    selection_background = "#2d4f67";
    selection_foreground = "#dcd7ba";
    cursor = "#dcd7ba";
    cursor_text_color = "#1f1f28";

    color0 = "#16161d";
    color8 = "#727169";
    color1 = "#c34043";
    color9 = "#e82424";
    color2 = "#76946a";
    color10 = "#98bb6c";
    color3 = "#c0a36e";
    color11 = "#e6c384";
    color4 = "#7e9cd8";
    color12 = "#7fb4ca";
    color5 = "#957fb8";
    color13 = "#938aa9";
    color6 = "#6a9589";
    color14 = "#7aa89f";
    color7 = "#c8c093";
    color15 = "#dcd7ba";
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
