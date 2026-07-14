{ config, pkgs, lib, ... }:

{
  # ── Steam + Proton ──────────────────────────────────────────────────────────
  # gamescopeSession gives a dedicated Wayland micro-compositor session for
  # gaming (good with NVIDIA + VRR). proton-ge-bin adds Proton-GE alongside
  # Valve's Proton for better per-title compatibility.
  programs.steam = {
    enable = true;
    gamescopeSession.enable = true;
    extraCompatPackages = [ pkgs.proton-ge-bin ];
    remotePlay.openFirewall = true;
  };

  programs.gamemode.enable = true;

  environment.systemPackages = with pkgs; [
    mangohud # in-game perf overlay
    lutris # non-Steam game launcher
    gamescope # standalone compositor
    protonup-qt # manage Proton-GE versions
  ];

  # The Steam library lives on the dedicated @games BTRFS subvolume (mounted at
  # /games — see hosts/pegasus/hardware-configuration.nix and disko.nix) so it
  # survives reinstalls. Point Steam at /games on first launch — see
  # hosts/pegasus/MANUAL-STEPS.md.
}
