{ config, pkgs, lib, ... }:

{
  # ── Ollama (CUDA) ───────────────────────────────────────────────────────────
  # The local inference backend on pegasus's RTX 4070. Listens on 127.0.0.1
  # only — it is NOT exposed directly; the Olla router (olla-router.nix) fronts
  # it and is the sole tailnet-facing entry point.
  # `services.ollama.acceleration` was removed in nixpkgs — CUDA is now selected
  # by choosing the CUDA package variant (verified against the pinned nixpkgs).
  services.ollama = {
    enable = true;
    package = pkgs.ollama-cuda;
    environmentVariables = {
      OLLAMA_KEEP_ALIVE = "5m";
    };
  };

  # ── Gaming-window drain ─────────────────────────────────────────────────────
  # While a game is running, pause ollama so the GPU's full VRAM/compute goes to
  # the game. The Olla router health-checks pegasus and drops it from the pool
  # automatically while ollama is down, then re-adds it when ollama returns.
  #
  # Mechanism: a symmetric oneshot. Starting it stops ollama; stopping it starts
  # ollama again. "Gaming on/off" maps to start/stop of this unit.
  systemd.services.ollama-pause = {
    description = "Pause ollama during gaming (GPU drain)";
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = "${pkgs.systemd}/bin/systemctl stop ollama.service";
      ExecStop = "${pkgs.systemd}/bin/systemctl start ollama.service";
    };
  };

  # STUB — confirm the "a game is launching" signal. We hook gamemode's
  # start/end (gamemode is enabled in gaming.nix; most Proton/Lutris titles
  # request it). gamemoded runs the start script when a game grabs gamemode and
  # the end script when it releases. Swap this for whatever signal Zoe prefers
  # (e.g. a Steam launch wrapper, a gamescope-session hook). See
  # hosts/pegasus/DECISIONS.md and MANUAL-STEPS.md.
  programs.gamemode.settings = lib.mkIf (config.programs.gamemode.enable or false) {
    custom = {
      start = "${pkgs.systemd}/bin/systemctl start ollama-pause.service";
      end = "${pkgs.systemd}/bin/systemctl stop ollama-pause.service";
    };
  };

  # ── Polkit: let the drain run unattended ────────────────────────────────────
  # gamemoded is a *user* unit, so the hooks above run as z — and touching a
  # system unit from there goes through polkit's manage-units action, which
  # prompts. A drain that needs a password dialog mid-launch is not a drain.
  # Scoped to this one unit and to start/stop, so it grants nothing else.
  security.polkit.extraConfig = ''
    polkit.addRule(function(action, subject) {
      if (action.id == "org.freedesktop.systemd1.manage-units" &&
          subject.user == "z" &&
          action.lookup("unit") == "ollama-pause.service" &&
          (action.lookup("verb") == "start" || action.lookup("verb") == "stop")) {
        return polkit.Result.YES;
      }
    });
  '';
}
