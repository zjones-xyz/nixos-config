{ config, pkgs, lib, ... }:

{
  # Jellyfin with Intel Quick Sync (VAAPI) hardware transcoding.
  #
  # Requires: media mounted at /mnt/media (NFS from Tower).
  # Access: http://memory-alpha.internal:8096
  # Pangolin resource target: http://localhost:8096 (Newt runs on this same
  # host — see newt.nix; a container name like `jellyfin` does NOT resolve).
  #
  # After first enable, complete setup at the web UI — Jellyfin generates its
  # own config/state in /var/lib/jellyfin.

  services.jellyfin = {
    enable = true;
    openFirewall = true;
    # Runs as the `jellyfin` user; add it to the `render` and `video` groups
    # for hardware transcoding access.
  };

  # Intel Quick Sync — exposes /dev/dri/renderD128 to the jellyfin user.
  hardware.graphics = {
    enable = true;
    extraPackages = with pkgs; [
      intel-media-driver   # iHD — required for 11th-gen (Tiger Lake) Quick Sync
      intel-compute-runtime
    ];
  };

  users.users.jellyfin.extraGroups = [ "render" "video" ];

  # Bind-mount media from NFS mount point into Jellyfin's expected path.
  # Adjust source path to match your NFS mount.
  # systemd.tmpfiles.rules = [
  #   "d /mnt/media 0755 jellyfin jellyfin -"
  # ];
}
