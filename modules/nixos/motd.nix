{ pkgs, self, ... }:

let
  # Baked in at eval time, so it's accurate for however/wherever this
  # generation was actually built (local switch, or --build-host/
  # --target-host from another machine) — unlike the generation number below,
  # which only exists once the profile switch happens on the target.
  revision = self.rev or self.dirtyRev or "dirty";
  shortRevision = self.shortRev or self.dirtyShortRev or "dirty";
in
{
  # Also exposed via `nixos-version --json` (.configurationRevision).
  system.configurationRevision = revision;

  # showMotd defaults to false per PAM service, so enabling it only for sshd
  # (and leaving every other service alone) makes this SSH-only — local
  # console logins stay silent.
  security.pam.services.sshd.showMotd = true;

  # A plain string path, not a Nix path literal — must NOT be store-copied,
  # since activationScripts.motd below regenerates this file's contents on
  # every switch/boot.
  users.motdFile = "/etc/nixos-motd";

  system.activationScripts.motd = ''
    link="$(readlink /nix/var/nix/profiles/system)"
    generation="''${link#system-}"
    generation="''${generation%-link}"

    # Best-effort: only works if this host has a local checkout at the
    # conventional ~/nixos-config path (see hosts/*/DEPLOY.md) with HEAD at
    # the revision that was actually built — silently omitted otherwise.
    subject=""
    if [ -d /home/z/nixos-config/.git ]; then
      subject="$(${pkgs.git}/bin/git -C /home/z/nixos-config log -1 --format='%s' 2>/dev/null || true)"
    fi

    {
      echo "NixOS generation $generation (rev ${shortRevision})"
      [ -n "$subject" ] && echo "Last commit: $subject"
    } > /etc/nixos-motd
  '';
}
