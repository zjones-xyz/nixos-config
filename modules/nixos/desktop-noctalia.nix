{ config, pkgs, lib, self, ... }:

let
  # Same pin as Umbriel, so the shell and compositor agree on Umbriel's IPC.
  noctalia = self.inputs.nixpkgs-umbriel.legacyPackages.${pkgs.stdenv.hostPlatform.system}.noctalia;

  # Basenames of the session files. SDDM exports the basename as
  # DESKTOP_SESSION, and each session imports it fresh into systemd --user.
  noctaliaSessions = [ "niri-noctalia" "umbriel" ];

  niriNoctaliaSession = (pkgs.writeTextDir "share/wayland-sessions/niri-noctalia.desktop" ''
    [Desktop Entry]
    Name=Niri (Noctalia)
    Comment=Niri with the Noctalia shell
    Exec=niri-session
    Type=Application
    DesktopNames=niri
  '').overrideAttrs (old: {
    passthru = (old.passthru or { }) // { providedSessions = [ "niri-noctalia" ]; };
  });

  # niri's config is shared by both niri sessions, so its shell binds name a
  # verb and this picks the shell. Dux's niri-settings.nix commands live here.
  shellIpc = pkgs.writeShellScriptBin "shell-ipc" ''
    verb="$1"
    case "''${DESKTOP_SESSION:-}" in
      ${lib.concatStringsSep "|" noctaliaSessions})
        case "$verb" in
          launcher) exec noctalia msg panel-toggle launcher ;;
          notifications) exec noctalia msg panel-toggle control-center notifications ;;
          settings) exec noctalia msg settings-toggle ;;
          powermenu) exec noctalia msg panel-toggle session ;;
          clipboard) exec noctalia msg panel-toggle clipboard ;;
          night) exec noctalia msg nightlight-toggle ;;
          lock) exec noctalia msg session lock ;;
          volume-up) exec noctalia msg volume-up ;;
          volume-down) exec noctalia msg volume-down ;;
          mute) exec noctalia msg volume-mute ;;
          micmute) exec noctalia msg mic-mute ;;
          brightness-up) exec noctalia msg brightness-up ;;
          brightness-down) exec noctalia msg brightness-down ;;
          notepad) exit 0 ;; # no Noctalia equivalent
        esac
        ;;
      *)
        case "$verb" in
          launcher) exec dms ipc spotlight toggle ;;
          notifications) exec dms ipc notifications toggle ;;
          settings) exec dms ipc settings toggle ;;
          powermenu) exec dms ipc powermenu toggle ;;
          clipboard) exec dms ipc clipboard toggle ;;
          night) exec dms ipc night toggle ;;
          lock) exec dms ipc lock lock ;;
          volume-up) exec dms ipc audio increment 3 ;;
          volume-down) exec dms ipc audio decrement 3 ;;
          mute) exec dms ipc audio mute ;;
          micmute) exec dms ipc audio micmute ;;
          brightness-up) exec dms ipc brightness increment 5 "" ;;
          brightness-down) exec dms ipc brightness decrement 5 "" ;;
          notepad) exec dms ipc notepad toggle ;;
        esac
        ;;
    esac
    echo "shell-ipc: unknown verb: $verb" >&2
    exit 2
  '';
in
{
  # ── Noctalia, for the Niri (Noctalia) and Umbriel sessions ──────────────────
  # Both shells hang off graphical-session.target, so each is gated on the
  # session or a login would run two shells and two notification daemons.
  # Why DESKTOP_SESSION, not a wrapper's marker: DECISIONS.md.
  environment.systemPackages = [ noctalia shellIpc ];
  xdg.sounds.enable = true;
  services.displayManager.sessionPackages = [ niriNoctaliaSession ];

  systemd.user.services.noctalia = {
    description = "Noctalia Wayland desktop shell";
    partOf = [ "graphical-session.target" ];
    after = [ "graphical-session.target" ];
    wantedBy = [ "graphical-session.target" ];
    path = lib.mkForce [ ];
    unitConfig.ConditionEnvironment = map (s: "|DESKTOP_SESSION=${s}") noctaliaSessions;
    serviceConfig = {
      ExecStart = lib.getExe noctalia;
      Restart = "on-failure";
    };
  };

  systemd.user.services.dms.unitConfig.ConditionEnvironment =
    map (s: "!DESKTOP_SESSION=${s}") noctaliaSessions;
}
