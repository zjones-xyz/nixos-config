{ config, pkgs, lib, ... }:

# ─────────────────────────────────────────────────────────────────────────────
# NFS auto-mounts via macOS autofs.
# ─────────────────────────────────────────────────────────────────────────────
# nix-darwin has no systemd, so the `fileSystems.<name>` + `x-systemd.automount`
# pattern used on the NixOS hosts (see hosts/memory-alpha/configuration.nix)
# doesn't translate here. macOS's own automounter (autofs) is the closest
# analog: shares mount on first access under the mount point and unmount when
# idle, so a laptop that roams off the home LAN doesn't hang trying to reach
# an NFS host at boot or login.
#
# This module is just the *mechanism* (writing /etc/auto_master + /etc/auto_nfs,
# reloading autofs on activation). The actual shares to mount are host data,
# not part of this module — set `services.macNfsAutomounts` in the host's own
# configuration.nix, mirroring how memory-alpha's NFS shares live in its own
# `fileSystems.*` entries rather than in the NixOS module that wires up mounts.
let
  cfg = config.services.macNfsAutomounts;

  mountLine = m: "${m.mountPoint}   ${m.options}   ${m.export}";
in
{
  options.services.macNfsAutomounts = lib.mkOption {
    default = [ ];
    description = "NFS shares to auto-mount via macOS autofs (see modules/darwin/nfs-mounts.nix).";
    type = lib.types.listOf (
      lib.types.submodule {
        options = {
          mountPoint = lib.mkOption {
            type = lib.types.str;
            example = "/mnt/media";
            description = "Absolute local mount point.";
          };
          export = lib.mkOption {
            type = lib.types.str;
            example = "tower.internal:/mnt/user/jellyfin";
            description = "NFS export, as host:/path.";
          };
          options = lib.mkOption {
            type = lib.types.str;
            default = "-fstype=nfs,soft,resvport,rw";
            description = "autofs mount options.";
          };
        };
      }
    );
  };

  config = {
    environment.etc."auto_master".text = ''
      +auto_master           # Use directory service
      /net                   -hosts          -nobrowse,hidefromfinder,nosuid
      /home                  auto_home       -nobrowse,hidefromfinder
      /Network/Servers       -fstab
      /-                     -static
      /-                     auto_nfs
    '';

    environment.etc."auto_nfs".text = ''
      # <absolute mount point>   <options>                          <NFS export>
    '' + lib.concatMapStringsSep "\n" mountLine cfg;

    # Reload autofs so /etc/auto_master + /etc/auto_nfs edits take effect
    # immediately after `darwin-rebuild switch` instead of requiring a reboot.
    system.activationScripts.postActivation.text = ''
      echo "Reloading autofs (NFS automounts)..." >&2
      /usr/sbin/automount -vc || true
    '';
  };
}
