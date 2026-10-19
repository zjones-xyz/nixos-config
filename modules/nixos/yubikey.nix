{ config, pkgs, lib, ... }:

let
  # Elevation prompts only (run0 authenticates through polkit-1). Session
  # login/unlock (greeters, screen lockers, login, su, sshd) stays
  # password-only: a key left plugged in must not unlock a locked session.
  u2fServices = [ "sudo" "polkit-1" ];
in
{
  # ── YubiKey: sudo/polkit touch + browser WebAuthn ───────────────────────────
  # Udev rules grant the active seat user (uaccess-tagged) non-root access to
  # the key's USB HID interface — on its own this is everything browsers need
  # for WebAuthn (Chrome/Firefox talk to the raw HID device directly, no PAM
  # involved).
  services.udev.packages = [ pkgs.yubikey-personalization ];

  # ── pam-u2f, scoped per service ─────────────────────────────────────────────
  # NOT `security.pam.u2f.enable`: every service's `u2f.enable` defaults to it,
  # which puts the key on all ~30 PAM stacks, sddm and the screen lockers
  # included. The settings below still apply to the services opted in.
  # "sufficient" (the default control) keeps the password as a fallback.
  security.pam.u2f.settings.cue = true; # "please touch the device" instead of a silent hang
  security.pam.services = lib.genAttrs u2fServices (_: { u2f.enable = true; });
  environment.systemPackages = [ pkgs.pam_u2f ]; # pamu2fcfg, for enrollment

  # polkit authenticates in this sandboxed unit; nixpkgs opens it to the key
  # and ~/.config/Yubico only under the global switch above, so do it here.
  systemd.services."polkit-agent-helper@".serviceConfig = {
    PrivateDevices = false;
    DeviceAllow = [ "/dev/urandom r" "char-hidraw rw" ];
    ProtectHome = "read-only";
  };

  # Without a sudo password prompt, PAM auth never runs and the key is never asked for.
  security.sudo.wheelNeedsPassword = true;

  # Checks the rendered stacks, not `u2f.enable`: raw-`text` services (e.g.
  # DMS's lockscreen.securityKey → `dankshell-u2f`) bypass the option.
  assertions =
    let
      withU2f = lib.attrNames (lib.filterAttrs (_: s: lib.hasInfix "pam_u2f.so" s.text) config.security.pam.services);
    in
    [{
      assertion = lib.sort lib.lessThan withU2f == lib.sort lib.lessThan u2fServices;
      message = "yubikey.nix: pam_u2f is in the PAM stacks of [${toString withU2f}], expected only [${toString u2fServices}].";
    }];

  # Enrollment is a manual, physical-key-present step z runs after rebuild:
  #   mkdir -p ~/.config/Yubico
  #   pamu2fcfg > ~/.config/Yubico/u2f_keys
  # (see hosts/pegasus/MANUAL-STEPS.md §13).
}
