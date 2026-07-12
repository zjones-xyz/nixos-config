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
}
