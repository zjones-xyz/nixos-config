{ config, pkgs, lib, ... }:

{
  # ── One keyring, chosen on purpose ──────────────────────────────────────────
  # The desktop modules silently pull in TWO Secret Service providers (Plasma's
  # kwalletd6/ksecretd via PAM, gnome-keyring via cosmic + niri), and whichever
  # wins org.freedesktop.secrets at first login holds it until a full logout —
  # surfacing as "the browser forgot my logins". gnome-keyring wins the tie:
  # it's what Niri's Secret portal is pinned to and the only one that works
  # unmodified in all four sessions. Full audit: hosts/pegasus/DECISIONS.md.
  services.gnome.gnome-keyring.enable = true;

  # ...and KWallet stops auto-unlocking a wallet nothing reads. Both are plain
  # `true` in nixpkgs' plasma6 module, so shadowing needs mkForce. Accepted
  # cost: a KDE app that genuinely wants the wallet prompts for its password
  # (nothing on this host does today). If Plasma becomes the daily driver
  # again, flipping these two back and disabling gnome-keyring is the change.
  security.pam.services.login.kwallet.enable = lib.mkForce false;
  security.pam.services.kde.kwallet.enable = lib.mkForce false;

  # Deliberately NOT programs.seahorse.enable, despite it being the obvious
  # GUI for browsing what ends up in here: that module also mkDefaults
  # programs.ssh.askPassword to seahorse's own askpass, which changes this
  # host's SSH prompting behaviour for something unrelated to the keyring.
  # `secret-tool` (pkgs.libsecret) covers inspection from a shell instead.
}
