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

  # ── Terminal theme: Catppuccin Macchiato ────────────────────────────────────
  # Colors live here (fleet-wide) so any host's terminal picks up the same
  # palette. alacritty is enabled fleet-wide (replaces the plain package
  # above — programs.alacritty pulls it in itself); kitty is only *themed*
  # here, not enabled — enabling stays per-host (e.g. hosts/pegasus/home.nix,
  # which also owns installing the kitty package — see niri-settings.nix).
  programs.alacritty = {
    enable = true;
    settings.colors = {
      primary = {
        background = "#24273a";
        foreground = "#cad3f5";
      };
      cursor = {
        text = "#24273a";
        cursor = "#f4dbd6";
      };
      selection = {
        background = "#f4dbd6";
        text = "#24273a";
      };
      normal = {
        black = "#494d64";
        red = "#ed8796";
        green = "#a6da95";
        yellow = "#eed49f";
        blue = "#8aadf4";
        magenta = "#f5bde6";
        cyan = "#8bd5ca";
        white = "#b8c0e0";
      };
      bright = {
        black = "#5b6078";
        red = "#ed8796";
        green = "#a6da95";
        yellow = "#eed49f";
        blue = "#8aadf4";
        magenta = "#f5bde6";
        cyan = "#8bd5ca";
        white = "#a5adcb";
      };
    };
  };

  programs.kitty.settings = {
    background = "#24273a";
    foreground = "#cad3f5";
    selection_background = "#f4dbd6";
    selection_foreground = "#24273a";
    cursor = "#f4dbd6";
    cursor_text_color = "#24273a";

    color0 = "#494d64";
    color8 = "#5b6078";
    color1 = "#ed8796";
    color9 = "#ed8796";
    color2 = "#a6da95";
    color10 = "#a6da95";
    color3 = "#eed49f";
    color11 = "#eed49f";
    color4 = "#8aadf4";
    color12 = "#8aadf4";
    color5 = "#f5bde6";
    color13 = "#f5bde6";
    color6 = "#8bd5ca";
    color14 = "#8bd5ca";
    color7 = "#b8c0e0";
    color15 = "#a5adcb";
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
