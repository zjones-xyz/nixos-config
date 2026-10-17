{ config, pkgs, lib, self, ... }:

let
  # Baked in at eval time, so it names the commit this closure was evaluated
  # from wherever it was built (local switch, or --build-host/--target-host).
  # Flakes expose no branch name, so the rev is the whole identity.
  revision = self.rev or self.dirtyRev or "unknown";
  shortRevision =
    if self ? shortRev then self.shortRev
    else if self ? dirtyShortRev then "${lib.removeSuffix "-dirty" self.dirtyShortRev} (dirty)"
    else "unknown";
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

  # ── Login line: generation, install time, rev ──
  # Describes the closure being activated ($systemConfig), not the newest
  # profile link — those differ after `boot` without a reboot, or a rollback
  # picked in the bootloader. The time is that generation link's mtime, so it
  # survives reboots; `nixos-rebuild test` registers no generation at all.
  system.activationScripts.motd = lib.stringAfter [ "etc" ] ''
    num=""
    for link in /nix/var/nix/profiles/system-*-link; do
      [ "$(readlink -f "$link")" = "$systemConfig" ] || continue
      n="''${link##*/system-}"
      n="''${n%-link}"
      if [ -z "$num" ] || [ "$n" -gt "$num" ]; then num="$n"; fi
    done

    if [ -n "$num" ]; then
      when="$(stat -c %Y "/nix/var/nix/profiles/system-$num-link")"
      what="generation $num, installed"
    else
      when="$(date +%s)"
      what="test activation (no generation),"
    fi
    when="$(date -d "@$when" '+%Y-%m-%d %H:%M %Z')"

    echo "NixOS $what $when from ${shortRevision}" > /etc/nixos-motd
  '';
}
