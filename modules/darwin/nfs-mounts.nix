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
# How it fits together:
#   - /etc/auto_master lists top-level autofs mount points and which "map"
#     file governs each. We keep macOS's defaults and add one more line
#     ("/-  auto_nfs") pointing autofs at our own direct map.
#   - /etc/auto_nfs is that direct map: each line is
#       <absolute mount point>   <options>   <NFS export>
#     and autofs creates/manages the mount point itself.
#   - `automount -vc` reloads autofs after activation so edits take effect
#     without a reboot or logout.
#
# STUB — no shares are wired up yet. Uncomment/edit an example line below once
# you know the export + local mount point you want. Modeled on the Tower NFS
# exports memory-alpha already mounts.
{
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
    # /mnt/media               -fstype=nfs,soft,resvport,rw        tower.internal:/mnt/user/jellyfin
    # /mnt/arr_managed_data    -fstype=nfs,soft,resvport,rw        tower.internal:/mnt/user/arr_managed_data
  '';

  # Reload autofs so /etc/auto_master + /etc/auto_nfs edits take effect
  # immediately after `darwin-rebuild switch` instead of requiring a reboot.
  system.activationScripts.postActivation.text = ''
    echo "Reloading autofs (NFS automounts)..." >&2
    /usr/sbin/automount -vc || true
  '';
}
