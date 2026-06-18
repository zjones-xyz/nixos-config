{ config, pkgs, lib, ... }:

{
  imports = [
    ./hardware-configuration.nix
    ../../modules/nixos/common.nix
    ../../modules/nixos/jellyfin.nix
    ../../modules/nixos/newt.nix
    ../../modules/nixos/traefik.nix
    ../../modules/nixos/dockge.nix
  ];

  networking.hostName = "memory-alpha";
  networking.networkmanager.enable = true;

  # ── Boot ──────────────────────────────────────────────────────────────────
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  # ── aarch64 emulation (build host for the Pis) ──────────────────────────────
  # Registers QEMU user-mode emulation for aarch64-linux via binfmt_misc, so
  # this x86_64 box can build aarch64 derivations. The Mac's linux-builder VM
  # is broken on macOS 26, and the Pis themselves are slow, so memory-alpha
  # becomes the aarch64 build host for hopper/hamilton.
  #
  # Use it as a remote build host when deploying a Pi:
  #   nixos-rebuild switch --flake .#hopper \
  #     --target-host z@hopper.internal \
  #     --build-host z@memory-alpha.internal \
  #     --use-remote-sudo
  #
  # Emulated builds are slower than native, but memory-alpha is far faster than
  # a Pi 4 even with the QEMU overhead — and it spares the Pi's SD card the
  # write churn of compiling.
  boot.binfmt.emulatedSystems = [ "aarch64-linux" ];

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
        "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQCfTHdojQvKOlTaaTYT2RmYMNKQ/6rBQwn6V+bPnrtASaI/G5E7RW67XGbZHi3K7EctyB9UP9Uw54sayEu4ebixI/dNFVVWeZ2byBQ49FoXh5o9Cfok0Qwf0QM7g9Td8O6Iu2ElnI8e+9cr8ThrfPpKmP68e6mpuYDvhQb4omcx8kRhxnsuNxkL2xCTNVxG/jw68o/1KHX++6tRqf0E3PBCjZ3Z8HMTdS8ouEBa8Y96GGeUvslwDJ9cUtLNCUhR5t3mGu3iSS9RYpFg/JujyTT9yhe2O/0og+OhBeSayGZMOXGWngGUEItExlbq2I4rMV5pFB1q+OyqksvlUfkJ/j3yJOii5uwonYvkWLZfR02yhn2b/bgOfYaimO5rfKj5jAC8bMRnWqLJAiG2qRDwtJT+ijyYlTKgLpz73sOGAQVvZygq11Vc35cZMFojlMeqAHdZMGi6XkUHnfZt8gyplw6VPV5EQnyDI4bRfY9sknuFvjHqdEzNyNrIEXtlmIB870s= z@Serenity.local"
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
  fileSystems."/mnt/unmanaged" = {
    device = "tower.internal:/mnt/user/jellyfin";
    fsType = "nfs";
    options = [ "nfsvers=4" "soft" "timeo=30" "x-systemd.automount" "noauto" "rsize=131072" "wsize=131072" "async" "nconnect=4" "noatime" ];
  };

  fileSystems."/mnt/arr_managed_data" = {
    device = "tower.internal:/mnt/user/arr_managed_data";
    fsType = "nfs";
    options = [ "nfsvers=4" "soft" "timeo=30" "x-systemd.automount" "noauto" "rsize=131072" "wsize=131072" "nconnect=4" "noatime" ];
  };

  # ── home-manager ──────────────────────────────────────────────────────────
  home-manager = {
    useGlobalPkgs = true;
    useUserPackages = true;
    users.z = import ./home.nix;
  };

  system.stateVersion = "26.05";
}
