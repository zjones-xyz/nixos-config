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

  # uaccess only applies to a user with an active logind *seat* session — an
  # SSH shell isn't seat-tracked, so liquidctl fails there without this
  # supplementary group-based grant. Needed for scripting/monitoring over SSH.
  services.udev.extraRules = ''
    SUBSYSTEMS=="usb", ATTRS{idVendor}=="1e71", GROUP="liquidctl", MODE="0660"
  '';
  users.groups.liquidctl = { };
  users.users.z.extraGroups = [ "liquidctl" ];

  # ── CoolerControl ────────────────────────────────────────────────────────────
  # Fan/pump curves bound to temperature sources; drives every cooling device
  # it can see, not just the Kraken (which it reaches through its own bundled
  # liquidctl copy, independent of the systemPackages entry above).
  # ⚠ One owner at a time: the daemon holds the pump's USB HID interface open,
  # so a hand-run `liquidctl set` fights it — use the GUI or stop the daemon.
  # There is no nvidiaSupport option to set; GPU sensors work as-is.
  programs.coolercontrol.enable = true;
}
