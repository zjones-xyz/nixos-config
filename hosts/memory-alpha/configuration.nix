{ config, pkgs, lib, ... }:

let
  # Predictable interface names (enp0s13f0u1u3c2, ...) encode the USB *port
  # path*, not the device — replugging either dongle into a different port
  # renames it. Pin friendly names to each dongle's MAC instead, which is
  # burned into the adapter and stays put regardless of which port it's in.
  # Applied both to the running system and the initrd stage so the LUKS SSH
  # unlock (below) sees the same names.
  #   eth-primary   = 6c:1f:f7:bc:55:f5 — the one DNS resolves memory-alpha.internal to
  #   eth-secondary = 9c:69:d3:4c:c5:16 — second USB-C Ethernet dongle. Now
  #                   carries a static address on the printer LAN,
  #                   192.168.8.98 (memory-alpha-2.internal), and is the
  #                   ipvlan parent for the Bambuddy virtual-printer network
  #                   in homelab-stacks (memory-alpha/bambuddy/compose.yaml) —
  #                   replacing what was previously the raw enp0s13f0u1u3c2
  #                   device name there.
  ethLinks = {
    "10-eth-primary" = {
      matchConfig.MACAddress = "6c:1f:f7:bc:55:f5";
      linkConfig.Name = "eth-primary";
    };
    "10-eth-secondary" = {
      matchConfig.MACAddress = "9c:69:d3:4c:c5:16";
      linkConfig.Name = "eth-secondary";
    };
  };
in
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

  systemd.network.links = ethLinks;

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

  # Legacy iptables kernel modules required by Tailscale's kernel-mode router
  # (TS_USERSPACE=false). NixOS defaults to nftables but does not load these
  # modules automatically; without them Tailscale fails to create its filter/nat
  # chains and MagicDNS DNAT breaks. The firewall backend stays as nftables.
  boot.kernelModules = [
    "ip_tables"
    "iptable_filter"
    "iptable_nat"
    "xt_conntrack"
    "xt_mark"
    "xt_MASQUERADE"
  ];

  # systemd-based initrd (26.05 default) — required for LUKS SSH unlock
  boot.initrd.systemd.enable = true;

  # Both of memory-alpha's real uplink NICs are identical USB-C Ethernet
  # dongles using the cdc_ncm/cdc_ether class drivers (confirmed via sysfs
  # driver links: /sys/class/net/<iface>/device/driver). hardware-configuration.nix's
  # boot.initrd.availableKernelModules only covers USB *storage*
  # (xhci_pci, usb_storage, ...), not USB *networking*, so no NIC ever came
  # up in the initrd stage — which is why the LUKS SSH unlock below was
  # unreachable and a KVM was required. Without this, DHCP in the initrd has
  # no interface to run on.
  #
  # (A third interface sometimes seen in `ip link` — enp0s20f0u1u4 — isn't a
  # host NIC at all: it's the NanoKVM's own composite-USB management
  # interface (RNDIS), present only while the KVM is plugged in. Irrelevant
  # to this fix.)
  boot.initrd.availableKernelModules = lib.mkAfter [
    "usbnet"
    "cdc_ether"
    "cdc_ncm"
    "mii"
  ];

  boot.initrd.systemd.network.links = ethLinks;

  # NixOS normally auto-generates a DHCP .network unit for the initrd
  # (genericDhcpNetworks in nixos/modules/tasks/network-interfaces-systemd.nix)
  # whenever boot.initrd.network.enable = true — but only when
  # networking.useDHCP is true. networking.networkmanager.enable = true above
  # implicitly sets networking.useDHCP = false (NetworkManager manages DHCP
  # for the *running* system instead), and that same flag gates the initrd's
  # auto-generated DHCP config, so no lease was ever requested in the initrd —
  # the NIC came up at the link layer but never got an IP. Define the DHCP
  # match explicitly here, scoped to the initrd only, independent of the main
  # system's NetworkManager-driven config.
  boot.initrd.systemd.network.networks."99-ethernet-default-dhcp" = {
    matchConfig = {
      Type = "ether";
      Kind = "!*";
    };
    DHCP = "yes";
  };

  # switch-root doesn't reset interface state — the initrd's DHCP-assigned
  # addresses/routes on eth-primary/eth-secondary (needed above for the LUKS
  # SSH unlock) survive into the real system. NetworkManager then finds those
  # interfaces already configured and adopts them as "connected (externally)"
  # instead of running its own DHCP client — which is the only thing that
  # populates /etc/resolv.conf. Net effect: routing works but DNS is empty on
  # every boot. Flush the addresses right before switch-root so NetworkManager
  # always starts from a clean interface and does its own full DHCP
  # negotiation, DNS included.
  boot.initrd.systemd.services.flush-network-before-switch-root = {
    description = "Flush initrd DHCP state so NetworkManager re-negotiates DNS";
    before = [ "initrd-switch-root.target" ];
    wantedBy = [ "initrd-switch-root.target" ];
    unitConfig.DefaultDependencies = false;
    serviceConfig.Type = "oneshot";
    path = [ pkgs.iproute2 ];
    script = ''
      ip addr flush dev eth-primary || true
      ip addr flush dev eth-secondary || true
    '';
  };

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

  # Audible chimes at the two initrd milestones that matter when unlocking
  # headlessly: (1) the SSH unlock server is up and reachable, and (2) LUKS
  # has actually been decrypted and boot is continuing. Without these there's
  # no feedback loop — you're left guessing whether `ssh root@... -p 2222` is
  # worth trying yet, or whether a submitted passphrase was accepted.
  #
  # Both just write BEL (\a) to /dev/console. The kernel's VT layer toggles
  # the PC speaker directly for that (kd_mksound, in drivers/tty/vt/vt.c) —
  # no ALSA, no `beep` package, nothing that needs to survive into the
  # initrd's minimal closure. Different beep counts/spacing so the two events
  # are distinguishable by ear alone.
  boot.initrd.systemd.services.chime-waiting-unlock = {
    description = "Chime: initrd SSH unlock server ready";
    after = [ "sshd.service" ];
    wantedBy = [ "initrd.target" ];
    before = [ "shutdown.target" ];
    conflicts = [ "shutdown.target" ];
    unitConfig.DefaultDependencies = false;
    serviceConfig.Type = "oneshot";
    path = [ pkgs.coreutils ];
    script = ''
      for i in 1 2 3; do
        printf '\a' > /dev/console
        sleep 0.15
      done
    '';
  };

  boot.initrd.systemd.services.chime-unlock-finished = {
    description = "Chime: LUKS unlock finished";
    after = [ "cryptsetup.target" ];
    wantedBy = [ "initrd.target" ];
    before = [ "shutdown.target" ];
    conflicts = [ "shutdown.target" ];
    unitConfig.DefaultDependencies = false;
    serviceConfig.Type = "oneshot";
    path = [ pkgs.coreutils ];
    script = ''
      for i in 1 2; do
        printf '\a' > /dev/console
        sleep 0.5
      done
    '';
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

  homelab.letsencryptStaging = false;

  system.stateVersion = "26.05";
}
