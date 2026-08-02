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

  # ── CoolerControl ────────────────────────────────────────────────────────────
  # GUI + coolercontrold, for fan/pump curves bound to temperature sources
  # rather than the one-shot `liquidctl set` calls above. Despite living in
  # this Kraken-named module it is not Kraken-specific: it drives every cooling
  # device it can see (hwmon-exposed case/CPU fans, the NVIDIA GPU), with the
  # Kraken as the reason we want it.
  #
  # It does take advantage of the Kraken: coolercontrold reaches NZXT AIOs
  # *through liquidctl*, not a kernel driver. nixpkgs' derivation wraps the
  # daemon with `pythonPath = [ liquidctl ]` (see
  # pkgs/applications/system/coolercontrol/coolercontrold.nix), so the daemon
  # carries its own copy — this does not depend on the systemPackages entry
  # above, which is there for CLI use. Since `liquidctl list` already detects
  # the pump on this box (2026-07-12, see the udev note above), CoolerControl
  # sees it through the same path.
  #
  # Caveat: one owner at a time. The daemon holds the pump's USB HID interface
  # open, so running `liquidctl set ...` by hand while coolercontrold is
  # driving it can fail or fight over the device. Use the GUI, or stop the
  # daemon first.
  #
  # No nvidiaSupport option to set — it was removed from the NixOS module
  # 2025-10-25 (drivers now load at runtime); the derivation runs
  # addDriverRunpath, so GPU sensors work without extra wiring.
  programs.coolercontrol.enable = true;
}
