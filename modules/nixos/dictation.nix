{ config, pkgs, lib, ... }:

{
  # ── Local push-to-talk dictation — Phase 1: injection layer only ───────────
  # ydotool injects text at the kernel level via /dev/uinput, which works
  # identically regardless of compositor (KWin today, niri later) — unlike
  # wtype's virtual-keyboard-unstable-v1 protocol, which KWin does not
  # implement. Confirmed empirically on pegasus (KWin 6.6.6): a live
  # wayland-info dump of the compositor's globals has no
  # zwp_virtual_keyboard_manager_v1. See hosts/pegasus/DECISIONS.md.
  #
  # programs.ydotool is nixpkgs' own module — it wires up a hardened
  # ydotoold service (DeviceAllow limited to /dev/uinput, no network,
  # minimal capabilities) and a dedicated group gating socket access, so
  # there's no hand-rolled udev rule to maintain here. We just need to put
  # the dictation user in that group.
  programs.ydotool.enable = true;

  users.users.z.extraGroups = [ config.programs.ydotool.group ];
}
