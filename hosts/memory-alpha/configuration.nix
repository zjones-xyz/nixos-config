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
  #                   the ipvlan parent for the Bambuddy virtual-printer
  #                   network in homelab-stacks
  #                   (memory-alpha/bambuddy/compose.yaml) — replacing what
  #                   was previously the raw enp0s13f0u1u3c2 device name
  #                   there. The addresses on that ipvlan network (Bambuddy's
  #                   own control address 192.168.8.98 /
  #                   memory-alpha-2.internal, plus three per-printer
  #                   addresses 192.168.8.95-97 for VP-athena/VP-conway/
  #                   VP-queue) are container-only — not addresses assigned
  #                   to eth-secondary itself.
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
    ../../modules/nixos/jellyfin-pretranscode.nix
    ../../modules/nixos/newt.nix
    ../../modules/nixos/traefik.nix
    ../../modules/nixos/dockge.nix
    ../../modules/nixos/arcane.nix
    ../../modules/nixos/nut-client.nix
    ../../modules/nixos/luks-remote-unlock.nix
    ./borgmatic.nix
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

  # ── LUKS SSH unlock ─────────────────────────────────────────────────────────
  # The shared flow (initrd SSH server, DHCP, pre-switch-root network flush,
  # chimes) lives in modules/nixos/luks-remote-unlock.nix, imported above.
  # Only memory-alpha's host-specific pieces stay here: the USB NIC drivers
  # and the MAC-pinned interface names.
  #
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
  # INERT until the §8 NFS cutover. Tower is galactica/ZFS now and these old
  # Unraid share paths (/mnt/user/…) aren't exported yet, so every mount
  # attempt gets `access denied`. `x-systemd.automount` is deliberately dropped
  # for now: with it, a consumer touching the mountpoint during a switch (e.g.
  # jellyfin restarting) fires a synchronous mount that fails and lands the
  # .mount unit in `failed` — which makes `nixos-rebuild switch` exit non-zero.
  # Without the automount and with `noauto`, nothing ever triggers them, so they
  # stay inert placeholders (no failed units) rather than hard errors. `nofail`
  # keeps them non-critical for good measure. The §8 cutover restores
  # `x-systemd.automount` and re-points device= at the real ZFS export paths.
  fileSystems."/mnt/unmanaged" = {
    device = "tower.internal:/mnt/user/jellyfin";
    fsType = "nfs";
    options = [ "nfsvers=4" "soft" "timeo=30" "noauto" "nofail" "rsize=131072" "wsize=131072" "async" "nconnect=4" "noatime" ];
  };

  fileSystems."/mnt/arr_managed_data" = {
    device = "tower.internal:/mnt/user/arr_managed_data";
    fsType = "nfs";
    options = [ "nfsvers=4" "soft" "timeo=30" "noauto" "nofail" "rsize=131072" "wsize=131072" "nconnect=4" "noatime" ];
  };

  # ── home-manager ──────────────────────────────────────────────────────────
  home-manager = {
    useGlobalPkgs = true;
    useUserPackages = true;
    users.z = import ./home.nix;
  };

  homelab.letsencryptStaging = false;

  # Real NVMe behind a real controller, so smartd has something to poll
  # (modules/nixos/smart.nix). `smartctl` itself ships fleet-wide regardless.
  homelab.smart.monitor = true;

  system.stateVersion = "26.05";
}
