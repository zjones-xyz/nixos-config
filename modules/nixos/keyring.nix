{ config, pkgs, lib, ... }:

{
  # ── One keyring, chosen on purpose ──────────────────────────────────────────
  # "Keyring" here means the D-Bus Secret Service (org.freedesktop.secrets):
  # the per-user encrypted store applications write to on their own
  # initiative — Chromium/Vivaldi's cookie+password encryption key, every
  # Electron app's safeStorage (vscode, Claude Desktop, Discord, Obsidian,
  # Ferdium, TickTick, ProtonMail Desktop, teams-for-linux — see home.nix),
  # Dropbox. It is a third tier, distinct from the two this repo already
  # names: sops-nix (machine secrets, decrypted at boot by the host key) and
  # 1Password (secrets a human deliberately retrieves — the op:// refs in
  # scripts/ipmi-remote.sh). Nothing declared this one, so it was settled by
  # a startup race.
  #
  # Three of this host's desktop modules each pull in a provider silently:
  #   - desktop-plasma.nix → Plasma 6 ships kwalletd6 + ksecretd (KDE's
  #     Secret Service bridge), and nixpkgs' plasma6 module wires pam_kwallet
  #     into the `login` PAM stack — which SDDM substacks, so it unlocked at
  #     every graphical login no matter which session was then picked.
  #   - desktop-cosmic.nix → the cosmic module sets
  #     services.gnome.gnome-keyring.enable = lib.mkDefault true.
  #   - desktop-niri.nix → nixpkgs' niri module does the same, and also pins
  #     the Secret portal to gnome-keyring (xdg.portal.config.niri.
  #     "org.freedesktop.impl.portal.Secret"), which that module's comment
  #     deliberately leaves unoverridden.
  # Evaluated against this closure before this file existed, BOTH providers
  # were enabled and both auto-unlocked at login.
  #
  # Why that is worse here than it sounds: pegasus's `systemd --user` manager
  # and graphical-session.target stay active across session switches (same
  # root cause as the dms.service / dcal.service "never auto-started" gotcha
  # — see DECISIONS.md), so whichever daemon wins org.freedesktop.secrets at
  # the first login holds it until a full logout or reboot, including after
  # switching from Niri into Plasma. Secrets written under one owner are
  # invisible under the other, which surfaces as "the browser forgot my
  # logins", not as anything recognisably keyring-shaped.
  #
  # gnome-keyring wins the tie: it is what Niri (the daily-driver session)
  # and COSMIC already default to, what niri's Secret portal is pinned to,
  # and the only one of the two that works unmodified in all four sessions on
  # this box. KWallet would need per-session glue everywhere except Plasma —
  # ksecretd is D-Bus-activatable only under org.kde.secretservicecompat,
  # never the name applications actually ask for, and kwallet-pam's
  # in-session half (plasma-kwallet-pam.service) carries no WantedBy outside
  # Plasma's own session units.
  services.gnome.gnome-keyring.enable = true;

  # ...and KWallet stops auto-unlocking a wallet nothing reads. Both of these
  # are plain `true` in nixpkgs' plasma6 module, so shadowing them needs
  # mkForce, not a competing default. kwalletd6 itself stays installed (it
  # comes with Plasma) — this only stops PAM handing it the login password at
  # every login, and with it the chance of ksecretd racing gnome-keyring for
  # the bus name.
  #
  # Accepted cost: in a Plasma/Dragonized session, a KDE app that genuinely
  # wants the wallet (plasma-nm storing a Wi-Fi PSK as user-owned, KDE PIM)
  # prompts for a wallet password instead of opening silently. Nothing on
  # this host does that today — it is wired ethernet (HARDWARE-MAP.md §1) and
  # runs no KDE PIM. If Plasma ever becomes the daily driver again, flipping
  # these two back and disabling gnome-keyring instead is the entire change.
  security.pam.services.login.kwallet.enable = lib.mkForce false;
  security.pam.services.kde.kwallet.enable = lib.mkForce false;

  # Deliberately NOT programs.seahorse.enable, despite it being the obvious
  # GUI for browsing what ends up in here: that module also mkDefaults
  # programs.ssh.askPassword to seahorse's own askpass, which changes this
  # host's SSH prompting behaviour for something unrelated to the keyring.
  # `secret-tool` (pkgs.libsecret) covers inspection from a shell instead.
}
