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

  options.homelab.smart.selfTests = lib.mkOption {
    type = lib.types.nullOr lib.types.str;
    default = null;
    example = "(S/../../7/03|L/../15/./03)";
    description = ''
      smartd `-s` regex scheduling drive self-tests (smartd.conf(5)), or null
      for none. Applies to every autodetected disk. Only meaningful with
      `monitor = true`.

      Results surface through the attributes Scrutiny already collects (a long
      test that hits bad sectors moves 197/198) and the drive's self-test log,
      so a host shipping to the Scrutiny hub has somewhere a person looks.
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
        # Self-tests are opt-in per host (selfTests above): only hosts whose
        # SMART data reaches Scrutiny have anyone reading the result.
        defaults.monitored = "-a -o on -S on"
          + lib.optionalString (config.homelab.smart.selfTests != null)
            " -s ${config.homelab.smart.selfTests}";

        # Wall messages: useless headless, noisy on a desktop.
        notifications.wall.enable = false;
      };
    })
  ];

  # ⟨Follow-up: route smartd alerts to ntfy via notifications.mail.mailer
  # (same pattern as nut.nix). Not wired yet — the cross-host ntfy URL is
  # unverified, and a guessed endpoint fails silently.⟩
}
