{ pkgs, ... }:

let
  # Same panels as niri-settings.nix; layout rationale is in that file.
  monLeft = "Dell Inc. DELL S2722QC 1NC1J24";
  monCentre = "LG Electronics LG HDR 4K 111NTEP7X460";
  monRight = "Dell Inc. DELL S2721QS 44B9513";

  workspaceDigits = [ 1 2 3 4 5 6 7 8 9 ];
  digitBinds = prefix: action: builtins.listToAttrs (map (n: {
    name = "${prefix}+${toString n}";
    value = "${action}:${toString n}";
  }) workspaceDigits);

  noctalia = command: "spawn:noctalia msg ${command}";
  whenLocked = action: { inherit action; allow_when_locked = true; };

  # ⚠ Uses the colon action syntax of the pinned Umbriel. Upstream replaced it
  # with word arguments on 2026-10-29, so moving the nixpkgs-umbriel pin past
  # that means rewriting these binds: MANUAL-STEPS.md §#PRNUM.
  settings = {
    general.autostart = [
      "protonmail-bridge-gui --no-window"
      "thunderbird"
      "ticktick"
    ];

    input = {
      keyboard.numlock_toggle = true;
      touchpad = {
        tap = true;
        natural_scroll = false;
      };
    };

    output = {
      ${monLeft} = {
        mode = "3840x2160@60";
        scale = 1.5;
        position = [ 0 704 ];
      };
      ${monCentre} = {
        mode = "3840x2160@60";
        scale = 1.25;
        position = [ 2560 416 ];
        focus_at_startup = true;
      };
      ${monRight} = {
        mode = "3840x2160@60";
        scale = 1.5;
        transform = "270";
        position = [ 5632 0 ];
      };
    };

    workspace = [
      {
        name = "Mail";
        output = monLeft;
      }
    ];

    # ⚠ No stream privacy in this session: the pinned Umbriel predates
    # block_capture and is_cast_target, and upstream has no layer-surface
    # equivalent. Windows and notifications niri hides will appear in streams.
    window_rule = [
      {
        match = {
          app_id = "firefox$";
          title = "^Picture-in-Picture$";
        };
        default_floating = true;
      }
      {
        match.app_id = "[Tt]hunderbird$";
        default_workspace = "Mail";
      }
      {
        match = {
          app_id = "[Tt]hunderbird$";
          at_startup = true;
        };
        default_focused = false;
      }
      {
        match = {
          app_id = "[Tt]ick[Tt]ick$";
          at_startup = true;
        };
        default_output = monRight;
        default_focused = false;
      }
      # No default_focused = false here: see the Steam rule in niri-settings.nix.
      {
        match.app_id = "^steam_app_[0-9]+$";
        default_output = monCentre;
      }
    ];

    # Mirrors the core of niri-settings.nix's binds.
    keybinds = {
      "Mod+T" = "spawn:kitty";
      "Mod+B" = "spawn:vivaldi --new-window";
      "Mod+Q" = "window-close";
      "Mod+O" = "overview-toggle";
      "Mod+Shift+Slash" = "cheatsheet-toggle";
      "Mod+Shift+E" = "session-quit";
      "Ctrl+Alt+Delete" = "session-quit";
      "Mod+Shift+P" = "dpms-off";
      "Mod+Escape" = "shortcuts-inhibit-toggle";

      "Mod+Space" = noctalia "panel-toggle launcher";
      "Mod+N" = noctalia "panel-toggle control-center notifications";
      "Mod+Comma" = noctalia "settings-toggle";
      "Mod+X" = noctalia "panel-toggle session";
      "Mod+V" = noctalia "panel-toggle clipboard";
      "Super+Alt+L" = noctalia "session lock";
      "Mod+Alt+N" = whenLocked (noctalia "nightlight-toggle");
      "Print" = noctalia "screenshot-region";
      "Ctrl+Print" = noctalia "screenshot-fullscreen";
      "Alt+Print" = noctalia "screenshot-window";

      "XF86AudioRaiseVolume" = whenLocked (noctalia "volume-up");
      "XF86AudioLowerVolume" = whenLocked (noctalia "volume-down");
      "XF86AudioMute" = whenLocked (noctalia "volume-mute");
      "XF86AudioMicMute" = whenLocked (noctalia "mic-mute");
      "XF86MonBrightnessUp" = whenLocked (noctalia "brightness-up");
      "XF86MonBrightnessDown" = whenLocked (noctalia "brightness-down");
      "XF86AudioPlay" = whenLocked "spawn:playerctl play-pause";
      "XF86AudioStop" = whenLocked "spawn:playerctl stop";
      "XF86AudioPrev" = whenLocked "spawn:playerctl previous";
      "XF86AudioNext" = whenLocked "spawn:playerctl next";

      "Mod+Left" = "window-focus-left";
      "Mod+Down" = "window-focus-down";
      "Mod+Up" = "window-focus-up";
      "Mod+Right" = "window-focus-right";
      "Mod+H" = "window-focus-left";
      "Mod+J" = "window-focus-down";
      "Mod+K" = "window-focus-up";
      "Mod+L" = "window-focus-right";

      "Mod+Ctrl+Left" = "column-move-left";
      "Mod+Ctrl+Down" = "window-move-down";
      "Mod+Ctrl+Up" = "window-move-up";
      "Mod+Ctrl+Right" = "column-move-right";
      "Mod+Ctrl+H" = "column-move-left";
      "Mod+Ctrl+J" = "window-move-down";
      "Mod+Ctrl+K" = "window-move-up";
      "Mod+Ctrl+L" = "column-move-right";

      "Mod+Home" = "column-focus-first";
      "Mod+End" = "column-focus-last";
      "Mod+Ctrl+Home" = "column-move-to-first";
      "Mod+Ctrl+End" = "column-move-to-last";

      "Mod+Shift+Left" = "output-focus-left";
      "Mod+Shift+Down" = "output-focus-down";
      "Mod+Shift+Up" = "output-focus-up";
      "Mod+Shift+Right" = "output-focus-right";
      "Mod+Shift+H" = "output-focus-left";
      "Mod+Shift+J" = "output-focus-down";
      "Mod+Shift+K" = "output-focus-up";
      "Mod+Shift+L" = "output-focus-right";

      "Mod+Shift+Ctrl+Left" = "column-move-to-output-left";
      "Mod+Shift+Ctrl+Down" = "column-move-to-output-down";
      "Mod+Shift+Ctrl+Up" = "column-move-to-output-up";
      "Mod+Shift+Ctrl+Right" = "column-move-to-output-right";

      "Mod+Page_Down" = "workspace-next";
      "Mod+Page_Up" = "workspace-previous";
      "Mod+U" = "workspace-next";
      "Mod+I" = "workspace-previous";
      "Mod+Ctrl+Page_Down" = "column-move-to-workspace-next";
      "Mod+Ctrl+Page_Up" = "column-move-to-workspace-previous";
      "Mod+Ctrl+U" = "column-move-to-workspace-next";
      "Mod+Ctrl+I" = "column-move-to-workspace-previous";

      "Mod+BracketLeft" = "window-consume-or-expel-left";
      "Mod+BracketRight" = "window-consume-or-expel-right";

      "Mod+R" = "window-cycle-primary-extent";
      "Mod+Shift+R" = "window-cycle-primary-extent-back";
      "Mod+F" = "window-toggle-maximize";
      "Mod+Shift+F" = "window-toggle-fullscreen";
      "Mod+M" = "window-toggle-maximize-to-edges";
      "Mod+C" = "column-center";
      "Mod+Minus" = "window-modify-primary-extent:-0.1";
      "Mod+Equal" = "window-modify-primary-extent:0.1";
      "Mod+Shift+Minus" = "window-modify-secondary-extent:-0.1";
      "Mod+Shift+Equal" = "window-modify-secondary-extent:0.1";
      "Mod+Ctrl+V" = "window-toggle-floating";
      "Mod+Shift+V" = "window-focus-switch-floating";
      "Mod+W" = "column-toggle-tabbed";
    } // digitBinds "Mod" "workspace-switch"
      // digitBinds "Mod+Ctrl" "column-move-to-workspace";
  };
in
{
  xdg.configFile."umbriel/config.toml".source =
    (pkgs.formats.toml { }).generate "umbriel-config.toml" settings;
}
