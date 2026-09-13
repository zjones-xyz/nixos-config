{ config, pkgs, lib, ... }:

{
  # ── SMART tooling, fleet-wide ───────────────────────────────────────────────
  # Imported from common.nix rather than per-host, so `smartctl` exists on every
  # NixOS box by construction and a new host cannot quietly miss it
  # (docs/DISK-DRAWER.md and PLATFORM.md §12 both assume it's there).

  options.homelab.smart.monitor = lib.mkOption {
    type = lib.types.bool;
    default = false;
    description = ''
      Run smartd to poll attached disks and log SMART state.

      Defaults to false because the fleet's Pis boot from SD or USB, which expose
      no SMART data at all — smartd there would monitor nothing and log about it
      on a timer. Enable per-host on machines with real disks behind a controller
      that passes SMART through.

      The `smartctl` binary is installed regardless of this setting; only the
      polling daemon is gated.
    '';
  };

  options.homelab.smart.standbyAware = lib.mkOption {
    type = lib.types.bool;
    default = false;
    description = ''
      Skip a disk's SMART poll while it is in standby, rather than spinning it
      up to read attributes.

      Defaults to false: on a host where nothing parks a disk the clause is
      inert, and on one where something does, skipping checks should be a
      deliberate choice rather than a fleet default. Enable it on hosts that
      deliberately park disks — the 30-minute poll otherwise defeats every
      spin-down on the box (galactica's PLATFORM.md §13e).

      Deliberately *without* smartd's `,q` suffix: the "is in STANDBY mode"
      line each skipped poll logs is the only cheap confirmation that the
      spin-down is actually holding.
    '';
  };

  config = lib.mkMerge [
    # Unconditional: the tool itself, everywhere.
    { environment.systemPackages = [ pkgs.smartmontools ]; }

    (lib.mkIf config.homelab.smart.monitor {
      services.smartd = {
        enable = true;
        autodetect = true;

        # Full attribute set + the drive's own offline collection/autosave.
        # Deliberately no `-s` self-test schedule until alerts go somewhere
        # a person actually reads (see below).
        defaults.monitored = "-a -o on -S on"
          + lib.optionalString config.homelab.smart.standbyAware " -n standby";

        # Wall messages: useless headless, noisy on a desktop.
        notifications.wall.enable = false;
      };
    })
  ];

  # ⟨Follow-up: route smartd alerts to ntfy via notifications.mail.mailer
  # (same pattern as nut.nix). Not wired yet — the cross-host ntfy URL is
  # unverified, and a guessed endpoint fails silently.⟩
}
