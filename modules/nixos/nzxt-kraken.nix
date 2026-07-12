{ config, pkgs, lib, ... }:

{
  # ── NZXT Kraken AIO liquid cooler ────────────────────────────────────────────
  # liquidctl talks to the pump directly over USB HID — no kernel driver
  # needed for control. (Only the much older X31/X40/X41/X60/X61 have an
  # in-kernel nzxt-kraken2 hwmon driver, and that's read-only temp/fan
  # reporting even then — liquidctl is still what you'd want for control.)
  environment.systemPackages = [ pkgs.liquidctl ];

  # liquidctl's own udev rules (lib/udev/rules.d/71-liquidctl.rules), covering
  # the whole NZXT vendor ID (1e71) — grants the active-seat user non-root
  # USB HID access via uaccess tagging, same mechanism as yubikey.nix.
  services.udev.packages = [ pkgs.liquidctl ];

  # uaccess only applies to a user with an active logind *seat* session (the
  # local console/graphical login) — confirmed the hard way (2026-07-12):
  # `liquidctl list` worked with no sudo at the desktop, but failed with
  # "ValueError: The device has no langid (permission issue...)" over SSH,
  # since an SSH shell isn't seat-tracked. Supplementary group-based grant so
  # this also works for scripting/monitoring over SSH, not just interactively
  # at the desktop.
  services.udev.extraRules = ''
    SUBSYSTEMS=="usb", ATTRS{idVendor}=="1e71", GROUP="liquidctl", MODE="0660"
  '';
  users.groups.liquidctl = { };
  users.users.z.extraGroups = [ "liquidctl" ];
}
