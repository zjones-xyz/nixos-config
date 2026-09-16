{ config, pkgs, lib, ... }:

let
  cfg = config.homelab.serialConsole;
in
{
  # Serial console selection, in one place so it can be overridden per-variant:
  # the device name is a property of the *machine*, not the config (Tower's BMC
  # SOL is COM2/ttyS1; a QEMU guest has only ttyS0), and a console= on a UART
  # that doesn't exist silently binds the login prompt to a device that never
  # appears. boot.kernelParams is a list, so a single entry cannot be removed
  # by an overriding module — hence a scalar option, which mkForce handles.
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
