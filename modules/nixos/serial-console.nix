{ config, pkgs, lib, ... }:

let
  cfg = config.homelab.serialConsole;
in
{
  # Serial console selection, in one place so it can be overridden per-variant.
  #
  # Exists because the device name is a property of the *machine*, not of the
  # config: Tower's BMC exposes Serial-over-LAN on COM2 (ttyS1), while a QEMU
  # guest has only ttyS0. Hardcoding ttyS1 in boot.kernelParams meant a VM
  # variant inherited it, registered a console on a UART that does not exist,
  # and systemd-getty-generator then bound the login prompt to a device that
  # would never appear — so the VM booted correctly in about five seconds and
  # presented no way to log in. Observed 2026-08-06; the only visible output was
  # via earlyprintk, which is write-only.
  #
  # No host imports this today — Tower's NixOS config has not been written yet
  # (hosts/galactica/DECISIONS.md, decision 3). Kept rather than deleted because
  # the BMC is unchanged and the lesson above is expensive to re-learn.
  #
  # boot.kernelParams is a list, so a single entry cannot be removed by an
  # overriding module — hence a scalar option, which mkForce handles cleanly.
  options.homelab.serialConsole = {
    device = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "ttyS1,115200n8";
      description = ''
        Serial console device and line settings, as they would appear after
        `console=` on the kernel command line. Null disables the serial console
        entirely, leaving only tty0.

        Set this to whatever the machine's firmware actually redirects to —
        check BIOS rather than assuming. A mismatch is quiet and costly: the
        kernel accepts a console on a non-existent UART without complaint, boot
        output goes nowhere, and the login prompt is bound to a device that
        never appears.
      '';
    };
  };

  config = lib.mkIf (cfg.device != null) {
    # Order matters. The kernel sends /dev/console — and therefore the
    # cryptsetup passphrase prompt — to the LAST console= argument, so the
    # serial line goes after tty0 deliberately. tty0 stays in the list so a
    # physically attached monitor still shows the boot; it just is not where
    # the prompt lands.
    boot.kernelParams = [
      "console=tty0"
      "console=${cfg.device}"
    ];
  };
}
