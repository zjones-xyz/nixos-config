{ config, pkgs, lib, ... }:

{
  # ── YubiKey: local login/sudo 2FA + browser WebAuthn ────────────────────────
  # Udev rules grant the active seat user (uaccess-tagged) non-root access to
  # the key's USB HID interface — on its own this is everything browsers need
  # for WebAuthn (Chrome/Firefox talk to the raw HID device directly, no PAM
  # involved).
  services.udev.packages = [ pkgs.yubikey-personalization ];

  # pam-u2f, left at its default "sufficient" control: touching the key is a
  # shortcut past the password prompt, never a replacement for it. Password
  # always still works if the key isn't plugged in or a user has no
  # enrollment file yet. Deliberately not "required" — this host already had
  # a login-lockout incident from an unrelated PAM/password gap (see
  # DECISIONS.md), and a 2FA setup that can lock z out entirely if the
  # enrollment file goes missing isn't worth it on a single-user workstation.
  security.pam.u2f = {
    enable = true;
    settings.cue = true; # prints "please touch the device" instead of hanging silently
  };
  security.pam.services.sudo.u2f.enable = true;
  # polkit-1 covers KDE's own "Authentication is required to..." dialogs
  # (System Settings, package installs, etc.) — the actual day-to-day
  # "local login" prompt on a desktop session, distinct from console/SDDM
  # greeter login, which this deliberately does not touch.
  security.pam.services.polkit-1.u2f.enable = true;

  # Enrollment is a manual, physical-key-present step z runs after rebuild:
  #   mkdir -p ~/.config/Yubico
  #   pamu2fcfg > ~/.config/Yubico/u2f_keys
  # (pamu2fcfg comes from pkgs.pam_u2f, pulled in automatically by
  # security.pam.u2f.enable — see hosts/pegasus/MANUAL-STEPS.md.)
}
