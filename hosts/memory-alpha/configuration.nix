{ config, pkgs, lib, ... }:

{
  imports = [
    ./hardware-configuration.nix
    ../../modules/nixos/common.nix
    ../../modules/nixos/jellyfin.nix
  ];

  networking.hostName = "memory-alpha";
  networking.networkmanager.enable = true;

  # ── Boot ──────────────────────────────────────────────────────────────────
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  # systemd-based initrd (26.05 default) — required for LUKS SSH unlock
  boot.initrd.systemd.enable = true;

  # LUKS SSH unlock — lets you decrypt the drive remotely after a reboot.
  #
  # How it works:
  #   1. A tiny SSH server starts in the initrd (before LUKS is unlocked).
  #   2. You SSH in and run `systemd-tty-ask-password-agent --query` to enter
  #      the passphrase (or send it via stdin with heredoc).
  #   3. The drive unlocks, the real system boots, the initrd SSH server exits.
  #
  # sops-nix age key interaction:
  #   sops-nix decrypts secrets using the host's SSH ed25519 key
  #   (/etc/ssh/ssh_host_ed25519_key), which lives on the encrypted volume.
  #   This is fine — sops secrets are only needed *after* LUKS unlock, during
  #   the normal boot activation stage, not in initrd.
  #
  # Setup steps (do once after install):
  #   1. Generate a dedicated initrd SSH host key (NOT the same as the main host key):
  #        ssh-keygen -t ed25519 -N "" -f /run/secrets/initrd-ssh-host-key
  #      Store it somewhere safe — it's an unencrypted secret embedded in initrd.
  #      Add to secrets/ and reference via sops after first boot if desired,
  #      but the simplest path is a key in /etc/secrets/initrd/ (unencrypted dir).
  #   2. Set `authorizedKeys` below to your public key.
  #   3. On reboot: ssh root@memory-alpha -p 2222
  #      then: systemd-tty-ask-password-agent --query
  boot.initrd.network = {
    enable = true;
    ssh = {
      enable = true;
      port = 2222;
      # Add your SSH public key here:
      authorizedKeys = [
        # "ssh-ed25519 AAAA... you@host"
      ];
      # Dedicated initrd host key — generate with:
      #   ssh-keygen -t ed25519 -N "" -f /etc/secrets/initrd/ssh_host_ed25519_key
      # This key lives OUTSIDE the encrypted volume (e.g., on /boot or hardcoded path).
      hostKeys = [ "/etc/secrets/initrd/ssh_host_ed25519_key" ];
    };
  };

  # ── sops-nix ──────────────────────────────────────────────────────────────
  # Uses the host's SSH ed25519 key as the age identity.
  # Get the age pubkey with:  ssh-to-age < /etc/ssh/ssh_host_ed25519_key.pub
  # Add that pubkey to .sops.yaml as a key for this machine.
  sops = {
    defaultSopsFile = ../../secrets/memory-alpha.yaml;
    age.sshKeyPaths = [ "/etc/ssh/ssh_host_ed25519_key" ];
    # Example secret reference:
    # secrets.example = {};
  };

  # ── NFS mounts (Tower media) ───────────────────────────────────────────────
  # Uncomment and adjust after Tower NFS exports are configured.
  # fileSystems."/mnt/media" = {
  #   device = "tower.local:/mnt/user/media";  # or Tailscale hostname
  #   fsType = "nfs";
  #   options = [ "nfsvers=4" "soft" "timeo=30" "x-systemd.automount" "noauto" ];
  # };

  # ── home-manager ──────────────────────────────────────────────────────────
  home-manager = {
    useGlobalPkgs = true;
    useUserPackages = true;
    users.z = import ./home.nix;
  };

  system.stateVersion = "26.05";
}
