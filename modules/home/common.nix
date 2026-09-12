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

  # ── Terminal theme: Rosé Pine ───────────────────────────────────────────────
  # Colors live here (fleet-wide) so any host's terminal picks up the same
  # palette. alacritty is enabled fleet-wide (replaces the plain package
  # above — programs.alacritty pulls it in itself); kitty is only *themed*
  # here, not enabled — enabling stays per-host (e.g. hosts/pegasus/home.nix,
  # which also owns installing the kitty package — see niri-settings.nix).
  # ANSI green is upstream's pine (teal) and cyan its rose — deliberate.
  programs.alacritty = {
    enable = true;
    settings.colors = {
      primary = {
        background = "#191724";
        foreground = "#e0def4";
      };
      cursor = {
        text = "#e0def4";
        cursor = "#524f67";
      };
      selection = {
        background = "#403d52";
        text = "#e0def4";
      };
      normal = {
        black = "#26233a";
        red = "#eb6f92";
        green = "#31748f";
        yellow = "#f6c177";
        blue = "#9ccfd8";
        magenta = "#c4a7e7";
        cyan = "#ebbcba";
        white = "#e0def4";
      };
      bright = {
        black = "#6e6a86";
        red = "#eb6f92";
        green = "#31748f";
        yellow = "#f6c177";
        blue = "#9ccfd8";
        magenta = "#c4a7e7";
        cyan = "#ebbcba";
        white = "#e0def4";
      };
    };
  };

  programs.kitty.settings = {
    background = "#191724";
    foreground = "#e0def4";
    selection_background = "#403d52";
    selection_foreground = "#e0def4";
    cursor = "#524f67";
    cursor_text_color = "#e0def4";

    color0 = "#26233a";
    color8 = "#6e6a86";
    color1 = "#eb6f92";
    color9 = "#eb6f92";
    color2 = "#31748f";
    color10 = "#31748f";
    color3 = "#f6c177";
    color11 = "#f6c177";
    color4 = "#9ccfd8";
    color12 = "#9ccfd8";
    color5 = "#c4a7e7";
    color13 = "#c4a7e7";
    color6 = "#ebbcba";
    color14 = "#ebbcba";
    color7 = "#e0def4";
    color15 = "#e0def4";
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
