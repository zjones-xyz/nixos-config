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

      ⚠ Also without a `,N` count, which is a real gap rather than an
      oversight: a disk that stays parked is never SMART-checked, for as long
      as it stays parked. That is the right trade for disks awaiting physical
      removal, and a deliberate blind spot if a live pool ever parks
      long-term — `standby,N` forces a check every N skipped polls if it stops
      being acceptable.

      ⚠ This flag covers neither `-o on` nor `-s`, both of which stay in the
      monitored string above. A drive's armed offline-collection routine can
      spin it up on its own, and a scheduled self-test has to spin it up to
      run at all — so on a host setting `selfTests` as well, the schedule
      defeats the spin-down this flag is protecting, at whatever hour the
      regex names. Neither is smartd's periodic poll, so neither shows as a
      skipped-poll line; galactica's PLATFORM.md §13e item 1 keeps the
      reasoning.
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
        # Self-tests are opt-in per host (selfTests): only hosts whose SMART
        # data reaches Scrutiny have anyone reading the result. ⚠ Both `-o on`
        # and `-s` spin a parked disk up regardless of `-n standby` — see
        # standbyAware's description.
        defaults.monitored = "-a -o on -S on"
          + lib.optionalString config.homelab.smart.standbyAware " -n standby"
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
