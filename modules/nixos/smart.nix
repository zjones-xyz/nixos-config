{ config, pkgs, lib, ... }:

{
  # ── SMART tooling, fleet-wide ───────────────────────────────────────────────
  # Imported from common.nix rather than per-host, so `smartctl` exists on every
  # NixOS box by construction and a new host cannot quietly miss it.
  #
  # This is the gap that motivated it: `docs/DISK-DRAWER.md` has carried "test any
  # disk before it is relied on as a spare, and periodically thereafter" as a
  # standing rule since it was written, and `hosts/galactica/PLATFORM.md` §12
  # specifies a UDMA_CRC_Error_Count baseline procedure — while no host in the
  # fleet actually shipped the binary those instructions call for.

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

  config = lib.mkMerge [
    # Unconditional: the tool itself, everywhere.
    { environment.systemPackages = [ pkgs.smartmontools ]; }

    (lib.mkIf config.homelab.smart.monitor {
      services.smartd = {
        enable = true;
        autodetect = true;

        # `-a` is the full attribute set; `-o on`/`-S on` enable the drive's own
        # offline collection and attribute autosave. Deliberately no `-s`
        # self-test schedule yet — see the note below, since a self-test that
        # fails into a journal nobody reads is not worth the I/O.
        defaults.monitored = "-a -o on -S on";

        # ⚠ Wall messages are useless on a headless server and merely noisy on a
        # desktop. Off until there is somewhere real for an alert to go.
        notifications.wall.enable = false;
      };
    })
  ];

  # ⟨Follow-up: route smartd alerts to ntfy.⟩ The fleet already has the pattern —
  # `modules/nixos/nut.nix` POSTs UPS events to the ntfy instance hopper runs, and
  # `services.smartd.notifications.mail.mailer` accepts an arbitrary script that
  # receives the message on stdin, which is the hook to reuse.
  #
  # Deliberately not wired here: nut.nix posts to 127.0.0.1:2586 because it *runs
  # on* hopper, and the cross-host URL other machines would need has not been
  # verified from this session. Shipping a guessed endpoint would mean alerts that
  # fail silently, which is worse than alerts that visibly do not exist yet.
  #
  # Until then this module makes SMART **readable and recorded** — attributes in
  # the journal, `smartctl` in every shell — which is the half that unblocks the
  # burn-in and baseline procedures already written down.
}
