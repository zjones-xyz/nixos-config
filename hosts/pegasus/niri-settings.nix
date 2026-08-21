{ config, pkgs, ... }:

{
  # ── Declarative niri config (niri-flake's homeModules.config) ──────────────
  # Migrated 2026-08-11 from a hand-edited ~/.config/niri/config.kdl (niri's
  # own auto-generated first-run template, with `natural-scroll` disabled by
  # hand) — see DECISIONS.md for why niri-flake was adopted this way
  # (homeModules.config only, NOT the full nixosModules.niri, which would
  # replace nixpkgs' niri package entirely).
  #
  # ⚠ DIVERGENCE RISK, flagged per Zoe's request: niri-flake's own README
  # states `programs.niri.settings`' schema is "not guaranteed to be
  # compatible with niri versions other than the two [niri-flake] provides"
  # and that nixpkgs' niri "will not have an issue... unless running old
  # versions 2+ releases behind." We deliberately run nixpkgs' niri (not
  # niri-flake's own build — see `package` below), so if nixpkgs' niri drifts
  # far enough behind niri-flake's schema, `nix flake check`/eval could start
  # failing (a new/renamed niri action, a KDL schema change) until niri-flake
  # is bumped, or (worse, if it happens silently) generate a config.kdl that
  # builds but doesn't do what's declared here. Symptom to watch for: an eval
  # error mentioning an unknown niri action name, or a real behavioral
  # mismatch between what's declared here and what actually happens on
  # pegasus. If that happens, check niri-flake's CHANGELOG/issues before
  # assuming it's a mistake in this file.
  # Validate against the niri actually installed (nixpkgs', via
  # programs.niri.enable in modules/nixos/desktop-niri.nix), not
  # niri-flake's own niri-stable build — see DECISIONS.md. Sibling of
  # `settings` below, not nested under it.
  programs.niri.package = pkgs.niri;

  programs.niri.settings = {
    # ── Session environment ────────────────────────────────────────────────
    # Recommended directly by DMS's own niri setup docs. Only the variables
    # that are safe or beneficial even if they leak into other sessions —
    # see the note below, this host's systemd --user manager is shared and
    # persistent across session switches (same root cause as the
    # XDG_CURRENT_DESKTOP bug in DECISIONS.md), and niri-session's own
    # script (`systemctl --user import-environment`) confirms it injects
    # into that shared manager, only explicitly cleaning up 5 unrelated
    # vars (WAYLAND_DISPLAY etc.) on exit — nothing we set here.
    #
    # QT_QPA_PLATFORM=wayland and the Electron Ozone hints are harmless (at
    # worst) or actively beneficial (at best) if they leak into Plasma/
    # COSMIC/Dragonized, since every session on this host is already
    # Wayland — matters for the Electron apps already installed (Discord,
    # VSCode, Obsidian, Ferdium, TickTick, Claude Desktop, ProtonMail
    # Desktop, Teams-for-linux — see home.nix), which otherwise fall back
    # to XWayland under niri.
    #
    # Deliberately NOT setting QT_QPA_PLATFORMTHEME=gtk3 (also in DMS's
    # docs) — that one is a real regression risk if it leaks: it would
    # override Plasma's native Qt/Breeze theming with GTK-styled dialogs
    # in the Plasma/Dragonized sessions, unlike the platform/Ozone vars
    # above which are session-agnostic.
    environment = {
      QT_QPA_PLATFORM = "wayland";
      # nixpkgs' own Electron wrapper checks for this specifically —
      # covers every Electron app above except Claude Desktop, which
      # comes via its own flake (claude-desktop-debian), not nixpkgs'
      # wrapper — hence also setting the generic upstream flag below.
      NIXOS_OZONE_WL = "1";
      ELECTRON_OZONE_PLATFORM_HINT = "auto";
    };

    input = {
      keyboard.numlock = true;

      touchpad = {
        # `tap` matches niri's own compiled-in default (true) — set
        # explicitly for clarity since it's central to how the trackpad is
        # actually used, not because it deviates from default.
        tap = true;
        # Confirmed live-tested 2026-08-11 (see MANUAL-STEPS.md §16): the
        # Magic Trackpad's Apple-convention scroll direction, reversed to
        # traditional PC convention. niri's own auto-generated template
        # shipped this ON by default — this is the one real behavioral
        # deviation from niri's stock defaults in this whole file.
        natural-scroll = false;
      };
    };

    # layout {}, animations {}, hotkey-overlay {}, and screenshot-path were
    # all left at niri-flake's schema defaults — cross-checked against the
    # original auto-generated config.kdl and, as far as could be confirmed
    # without a real niri build here, they matched niri's actual compiled-in
    # defaults rather than being template-only opinions (unlike the binds
    # and spawn-at-startup below, which were NOT left as defaults — see
    # those sections for why).

    # waybar dropped entirely (was the auto-generated template's suggested
    # bar) — DMS is the bar/shell now, started via its own systemd --user
    # service (programs.dank-material-shell.systemd.enable = true in
    # modules/nixos/desktop-niri.nix), not spawn-at-startup.

    window-rules = [
      # Kept from the original config: open Firefox's picture-in-picture
      # player as floating. Firefox is actually installed on this host
      # (unlike the original's other window-rule, for WezTerm, which isn't
      # — dropped).
      {
        matches = [
          {
            app-id = "firefox$";
            title = "^Picture-in-Picture$";
          }
        ];
        open-floating = true;
      }
    ];

    binds = with config.lib.niri.actions; {
      "Mod+Shift+Slash".action = show-hotkey-overlay;

      # Terminal: kitty, not the original template's suggested alacritty
      # (not installed here) — per Zoe, 2026-08-11.
      "Mod+T" = {
        hotkey-overlay.title = "Open a Terminal: kitty";
        action = spawn "kitty";
      };
      # Mod+D (launcher) and the original Super+Alt+L->swaylock dropped/
      # replaced — DMS owns both roles now (Mod+Space spotlight below,
      # Super+Alt+L -> DMS's own lock screen). Neither fuzzel nor swaylock
      # is installed on this host.
      "Super+Alt+L" = {
        hotkey-overlay.title = "Toggle Lock Screen";
        action = spawn "dms" "ipc" "lock" "lock";
      };

      # Screen reader toggle — kept from the original template as a
      # harmless no-cost escape hatch (orca isn't installed, so this is
      # inert until/unless it is; matches niri's own suggested default).
      "Super+Alt+S" = {
        allow-when-locked = true;
        hotkey-overlay.hidden = true;
        action = spawn-sh "pkill orca || exec orca";
      };

      # Volume/brightness routed through DMS instead of the original
      # template's raw wpctl/brightnessctl calls, so DMS's own on-screen
      # volume/brightness indicators actually fire — matches DMS's own
      # distro/nix/niri.nix bind list exactly (including its brightness
      # action's odd trailing empty-string argument, which is upstream's,
      # not a typo here).
      "XF86AudioRaiseVolume" = {
        allow-when-locked = true;
        action = spawn "dms" "ipc" "audio" "increment" "3";
      };
      "XF86AudioLowerVolume" = {
        allow-when-locked = true;
        action = spawn "dms" "ipc" "audio" "decrement" "3";
      };
      "XF86AudioMute" = {
        allow-when-locked = true;
        action = spawn "dms" "ipc" "audio" "mute";
      };
      "XF86AudioMicMute" = {
        allow-when-locked = true;
        action = spawn "dms" "ipc" "audio" "micmute";
      };
      "XF86MonBrightnessUp" = {
        allow-when-locked = true;
        action = spawn "dms" "ipc" "brightness" "increment" "5" "";
      };
      "XF86MonBrightnessDown" = {
        allow-when-locked = true;
        action = spawn "dms" "ipc" "brightness" "decrement" "5" "";
      };

      # Media transport keys (play/pause/etc) have no DMS equivalent — kept
      # as the original template's playerctl bindings, unchanged.
      "XF86AudioPlay" = {
        allow-when-locked = true;
        action = spawn-sh "playerctl play-pause";
      };
      "XF86AudioStop" = {
        allow-when-locked = true;
        action = spawn-sh "playerctl stop";
      };
      "XF86AudioPrev" = {
        allow-when-locked = true;
        action = spawn-sh "playerctl previous";
      };
      "XF86AudioNext" = {
        allow-when-locked = true;
        action = spawn-sh "playerctl next";
      };

      "Mod+O" = {
        repeat = false;
        action = toggle-overview;
      };
      "Mod+Q" = {
        repeat = false;
        action = close-window;
      };

      "Mod+Left".action = focus-column-left;
      "Mod+Down".action = focus-window-down;
      "Mod+Up".action = focus-window-up;
      "Mod+Right".action = focus-column-right;
      "Mod+H".action = focus-column-left;
      "Mod+J".action = focus-window-down;
      "Mod+K".action = focus-window-up;
      "Mod+L".action = focus-column-right;

      "Mod+Ctrl+Left".action = move-column-left;
      "Mod+Ctrl+Down".action = move-window-down;
      "Mod+Ctrl+Up".action = move-window-up;
      "Mod+Ctrl+Right".action = move-column-right;
      "Mod+Ctrl+H".action = move-column-left;
      "Mod+Ctrl+J".action = move-window-down;
      "Mod+Ctrl+K".action = move-window-up;
      "Mod+Ctrl+L".action = move-column-right;

      "Mod+Home".action = focus-column-first;
      "Mod+End".action = focus-column-last;
      "Mod+Ctrl+Home".action = move-column-to-first;
      "Mod+Ctrl+End".action = move-column-to-last;

      "Mod+Shift+Left".action = focus-monitor-left;
      "Mod+Shift+Down".action = focus-monitor-down;
      "Mod+Shift+Up".action = focus-monitor-up;
      "Mod+Shift+Right".action = focus-monitor-right;
      "Mod+Shift+H".action = focus-monitor-left;
      "Mod+Shift+J".action = focus-monitor-down;
      "Mod+Shift+K".action = focus-monitor-up;
      "Mod+Shift+L".action = focus-monitor-right;

      "Mod+Shift+Ctrl+Left".action = move-column-to-monitor-left;
      "Mod+Shift+Ctrl+Down".action = move-column-to-monitor-down;
      "Mod+Shift+Ctrl+Up".action = move-column-to-monitor-up;
      "Mod+Shift+Ctrl+Right".action = move-column-to-monitor-right;
      "Mod+Shift+Ctrl+H".action = move-column-to-monitor-left;
      "Mod+Shift+Ctrl+J".action = move-column-to-monitor-down;
      "Mod+Shift+Ctrl+K".action = move-column-to-monitor-up;
      "Mod+Shift+Ctrl+L".action = move-column-to-monitor-right;

      "Mod+Page_Down".action = focus-workspace-down;
      "Mod+Page_Up".action = focus-workspace-up;
      "Mod+U".action = focus-workspace-down;
      "Mod+I".action = focus-workspace-up;
      "Mod+Ctrl+Page_Down".action = move-column-to-workspace-down;
      "Mod+Ctrl+Page_Up".action = move-column-to-workspace-up;
      "Mod+Ctrl+U".action = move-column-to-workspace-down;
      "Mod+Ctrl+I".action = move-column-to-workspace-up;

      "Mod+Shift+Page_Down".action = move-workspace-down;
      "Mod+Shift+Page_Up".action = move-workspace-up;
      "Mod+Shift+U".action = move-workspace-down;
      "Mod+Shift+I".action = move-workspace-up;

      "Mod+WheelScrollDown" = {
        cooldown-ms = 150;
        action = focus-workspace-down;
      };
      "Mod+WheelScrollUp" = {
        cooldown-ms = 150;
        action = focus-workspace-up;
      };
      "Mod+Ctrl+WheelScrollDown" = {
        cooldown-ms = 150;
        action = move-column-to-workspace-down;
      };
      "Mod+Ctrl+WheelScrollUp" = {
        cooldown-ms = 150;
        action = move-column-to-workspace-up;
      };

      "Mod+WheelScrollRight".action = focus-column-right;
      "Mod+WheelScrollLeft".action = focus-column-left;
      "Mod+Ctrl+WheelScrollRight".action = move-column-right;
      "Mod+Ctrl+WheelScrollLeft".action = move-column-left;

      "Mod+Shift+WheelScrollDown".action = focus-column-right;
      "Mod+Shift+WheelScrollUp".action = focus-column-left;
      "Mod+Ctrl+Shift+WheelScrollDown".action = move-column-right;
      "Mod+Ctrl+Shift+WheelScrollUp".action = move-column-left;

      "Mod+1".action = focus-workspace 1;
      "Mod+2".action = focus-workspace 2;
      "Mod+3".action = focus-workspace 3;
      "Mod+4".action = focus-workspace 4;
      "Mod+5".action = focus-workspace 5;
      "Mod+6".action = focus-workspace 6;
      "Mod+7".action = focus-workspace 7;
      "Mod+8".action = focus-workspace 8;
      "Mod+9".action = focus-workspace 9;
      # move-column-to-workspace (unlike its -up/-down siblings above) isn't
      # in niri-flake's config.lib.niri.actions cache — presumably its
      # workspace-index-or-name argument type is too complex for that
      # cache's generator. Uses the documented action.<name>=value form
      # instead of the `with`-scoped bare name.
      "Mod+Ctrl+1".action.move-column-to-workspace = 1;
      "Mod+Ctrl+2".action.move-column-to-workspace = 2;
      "Mod+Ctrl+3".action.move-column-to-workspace = 3;
      "Mod+Ctrl+4".action.move-column-to-workspace = 4;
      "Mod+Ctrl+5".action.move-column-to-workspace = 5;
      "Mod+Ctrl+6".action.move-column-to-workspace = 6;
      "Mod+Ctrl+7".action.move-column-to-workspace = 7;
      "Mod+Ctrl+8".action.move-column-to-workspace = 8;
      "Mod+Ctrl+9".action.move-column-to-workspace = 9;

      "Mod+BracketLeft".action = consume-or-expel-window-left;
      "Mod+BracketRight".action = consume-or-expel-window-right;

      # Moved off Mod+Comma/Mod+Period (the original template's bindings) —
      # DMS wants Mod+Comma for its settings panel (below). Mod+BracketLeft/
      # Right above cover the general consume-or-expel case anyway; these
      # two are the narrower single-direction variants, remapped rather
      # than dropped so nothing silently disappears.
      "Mod+Shift+Comma".action = consume-window-into-column;
      "Mod+Shift+Period".action = expel-window-from-column;

      "Mod+R".action = switch-preset-column-width;
      "Mod+Shift+R".action = switch-preset-column-width-back;
      "Mod+Ctrl+Shift+R".action = switch-preset-window-height;
      "Mod+Ctrl+R".action = reset-window-height;

      "Mod+F".action = maximize-column;
      "Mod+Shift+F".action = fullscreen-window;
      "Mod+M".action = maximize-window-to-edges;
      "Mod+Ctrl+F".action = expand-column-to-available-width;
      "Mod+C".action = center-column;
      "Mod+Ctrl+C".action = center-visible-columns;

      "Mod+Minus".action = set-column-width "-10%";
      "Mod+Equal".action = set-column-width "+10%";
      "Mod+Shift+Minus".action = set-window-height "-10%";
      "Mod+Shift+Equal".action = set-window-height "+10%";

      # Moved off Mod+V (the original template's binding) — DMS wants
      # Mod+V for its clipboard manager (below). Paired with the existing
      # Mod+Shift+V below, same as before.
      "Mod+Ctrl+V".action = toggle-window-floating;
      "Mod+Shift+V".action = switch-focus-between-floating-and-tiling;

      "Mod+W".action = toggle-column-tabbed-display;

      # screenshot/screenshot-screen/screenshot-window aren't in
      # niri-flake's config.lib.niri.actions cache either (they take
      # optional properties, e.g. show-pointer) — same documented
      # action.<name>=value form as above.
      "Print".action.screenshot = { };
      "Ctrl+Print".action.screenshot-screen = { };
      "Alt+Print".action.screenshot-window = { };

      # Markup pass on whatever the binds above just put on the clipboard —
      # niri copies every screenshot to the clipboard automatically (see
      # home.nix's programs.swappy comment for the doc citation), so this is
      # deliberately NOT a grim+slurp+swappy pipeline, which would duplicate
      # the capture niri already does above. swappy itself only edits, it
      # doesn't capture. wl-paste comes from wl-clipboard, swappy is enabled
      # + configured via programs.swappy — both in home.nix.
      "Mod+Shift+S" = {
        hotkey-overlay.title = "Annotate Last Screenshot (swappy)";
        action = spawn-sh "wl-paste --type image/png | swappy -f -";
      };

      # Escape hatch for exactly the situation this host is tested under —
      # remote/KVM input — kept from the original template unchanged.
      "Mod+Escape" = {
        allow-inhibiting = false;
        action = toggle-keyboard-shortcuts-inhibit;
      };

      "Mod+Shift+E".action = quit;
      "Ctrl+Alt+Delete".action = quit;
      "Mod+Shift+P".action = power-off-monitors;

      # ── DMS keybinds ──────────────────────────────────────────────────
      # Hand-written here rather than via DMS's own homeModules.niri +
      # enableKeybinds — that module needs DMS's homeModules.dank-
      # material-shell also imported (for its `cfg.enable` reference to
      # resolve), which would pull in a `programs.quickshell` home-manager
      # option this repo deliberately avoided by using DMS's NixOS module
      # for the actual install (see DECISIONS.md and
      # modules/nixos/desktop-niri.nix). These lines are transcribed
      # directly from DMS's distro/nix/niri.nix so they match upstream's
      # own bind set.
      "Mod+Space" = {
        hotkey-overlay.title = "Toggle Application Launcher";
        action = spawn "dms" "ipc" "spotlight" "toggle";
      };
      "Mod+N" = {
        hotkey-overlay.title = "Toggle Notification Center";
        action = spawn "dms" "ipc" "notifications" "toggle";
      };
      "Mod+Comma" = {
        hotkey-overlay.title = "Toggle Settings";
        action = spawn "dms" "ipc" "settings" "toggle";
      };
      "Mod+P" = {
        hotkey-overlay.title = "Toggle Notepad";
        action = spawn "dms" "ipc" "notepad" "toggle";
      };
      "Mod+X" = {
        hotkey-overlay.title = "Toggle Power Menu";
        action = spawn "dms" "ipc" "powermenu" "toggle";
      };
      "Mod+V" = {
        hotkey-overlay.title = "Toggle Clipboard Manager";
        action = spawn "dms" "ipc" "clipboard" "toggle";
      };
      "Mod+Alt+N" = {
        allow-when-locked = true;
        hotkey-overlay.title = "Toggle Night Mode";
        action = spawn "dms" "ipc" "night" "toggle";
      };
    };
  };
}
