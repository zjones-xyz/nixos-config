{ config, pkgs, lib, ... }:

let
  # secrets/tower-hv.yaml does not exist in the repo yet — it must be created by
  # Zoe once the host has booted and its age key is known (see DEPLOY.md
  # § sops). Gated on the file's presence so the closure evaluates cleanly until
  # then, and activates automatically once the encrypted file is committed.
  # Same pattern as hosts/pegasus/configuration.nix.
  hasSops = builtins.pathExists ../../secrets/tower-hv.yaml;

  # TODO(install): confirm with `ip -br link` on the machine. X9SCM-F carries
  # two Intel NICs (82579LM + 82574L, both e1000e); predictable naming usually
  # lands them as eno1/eno2 but the firmware's onboard index is not guaranteed.
  # This is the ONLY place the name appears — fix it here.
  hostNic = "eno1";
in
{
  imports = [
    ./hardware-configuration.nix
    ../../modules/nixos/common.nix
    ../../modules/nixos/vfio.nix
  ];

  # ── Identity ────────────────────────────────────────────────────────────────
  # Deliberately NOT "tower". `tower.internal` stays pointed at the Unraid
  # instance, which is what memory-alpha's NFS mounts
  # (hosts/memory-alpha/configuration.nix) and NUT client
  # (modules/nixos/nut-client.nix) resolve. The reason is the fallback
  # guarantee: booted bare-metal, that machine *is* tower.internal, so if this
  # host took the name, falling back would require DNS/DHCP surgery every time.
  # The hypervisor is a separate fleet identity with its own DHCP reservation.
  networking.hostName = "tower-hv";
  networking.domain = "internal";

  # ── Boot ────────────────────────────────────────────────────────────────────
  # systemd-boot, matching memory-alpha/pegasus. Requires the board to be in
  # UEFI (or Dual) boot mode — see DEPLOY.md § Bootloader for the legacy/GRUB
  # alternative and why you might deliberately choose it. hosts/tower-hv/disko.nix
  # provisions a BIOS boot partition either way so switching does not mean
  # repartitioning.
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  # Keep a couple of generations only. /boot is on a 120GB SSD shared with
  # nothing else, but Unraid's flash drive is the fallback path and a cluttered
  # boot menu is one more thing to get wrong at 3am.
  boot.loader.systemd-boot.configurationLimit = 10;

  # ── Serial console (IPMI Serial-over-LAN) ───────────────────────────────────
  # This is load-bearing, not a convenience: the LUKS passphrase prompt has to
  # appear somewhere reachable, and until initrd SSH unlock is wired up (see
  # below) that somewhere is IPMI SoL:
  #   ipmiconsole -h 192.168.8.191 -u ADMIN -P
  #
  # Order matters. The kernel sends /dev/console — and therefore the cryptsetup
  # prompt — to the LAST console= argument, so the serial line is listed last
  # on purpose. tty0 stays in the list so a physically attached monitor still
  # shows the boot, it just isn't where the prompt lands.
  #
  # TODO(install): confirm the unit and baud in BIOS under Advanced → Serial
  # Port Console Redirection. Supermicro X9 boards conventionally expose SoL on
  # COM2 (= ttyS1) at 115200, but the BIOS setting is authoritative and a
  # mismatch here means a blank IPMI console that looks exactly like a hang.
  boot.kernelParams = [
    "console=tty0"
    "console=ttyS1,115200n8"
  ];
  systemd.services."serial-getty@ttyS1" = {
    enable = true;
    wantedBy = [ "getty.target" ];
    serviceConfig.Restart = "always";
  };

  # ── LUKS ────────────────────────────────────────────────────────────────────
  # The root disk is encrypted from install time (see hosts/tower-hv/disko.nix
  # and hardware-configuration.nix). Unlock is MANUAL, over the serial console
  # above, by design for now.
  #
  # Initrd SSH unlock — the `unlock-memory-alpha` / `unlock-pegasus` pattern in
  # scripts/luks-unlock-remote.sh — is deliberately NOT wired up yet. It is the
  # fiddliest part of both existing hosts (the initrd NIC driver and the
  # NetworkManager DHCP-flush interaction each took real debugging), and none of
  # it needs to work to prove SATA passthrough. Adding it later is a plain
  # `nixos-rebuild switch`, not a reinstall, which is the whole reason LUKS goes
  # down at install time rather than after.
  #
  # When you do want it, copy the block from hosts/pegasus/configuration.nix and
  # adjust: set boot.initrd.systemd.enable = true, add "e1000e" to
  # boot.initrd.availableKernelModules, generate the dedicated initrd host key
  # (`ssh-keygen -t ed25519 -N "" -f /etc/secrets/initrd/ssh_host_ed25519_key`),
  # and add an `unlock-tower-hv` alias to hosts/serenity/home.nix. The
  # flush-network-before-switch-root workaround that both other hosts need is
  # NOT required here — that bug is specific to NetworkManager adopting the
  # initrd's lease, and this host runs systemd-networkd (see below).

  # ── Networking: br0 for the guest ───────────────────────────────────────────
  # The Unraid guest must present the same LAN identity it does on bare metal —
  # it serves NFS to memory-alpha and (once the UPS moves) talks NUT. NAT or
  # macvtap would both change how it is reached, which would mean the evaluation
  # measures the workaround rather than the storage stack. A plain bridge keeps
  # it indistinguishable from bare metal: same DHCP reservation, same address.
  #
  # systemd-networkd rather than NetworkManager, which is a deliberate departure
  # from memory-alpha/pegasus. Two reasons: declarative bridges are markedly
  # less fussy here, and it sidesteps the NetworkManager-adopts-the-initrd-lease
  # bug that both other hosts needed a switch-root workaround for — which is
  # exactly the bug that would otherwise bite when initrd SSH unlock gets added.
  networking.useNetworkd = true;
  networking.useDHCP = false;

  systemd.network = {
    enable = true;

    netdevs."10-br0".netdevConfig = {
      Name = "br0";
      Kind = "bridge";
    };

    # Physical NIC: no address of its own, just enslaved to the bridge.
    networks."10-${hostNic}" = {
      matchConfig.Name = hostNic;
      networkConfig.Bridge = "br0";
      # "enslaved" not "routable" — this interface never gets an IP, so waiting
      # for it to be routable would stall network-online.target until timeout
      # on every single boot.
      linkConfig.RequiredForOnline = "enslaved";
    };

    # The bridge carries the host's own address.
    networks."20-br0" = {
      matchConfig.Name = "br0";
      networkConfig = {
        DHCP = "ipv4";
        # Bridges default to a ~2s forward delay + STP learning; without this a
        # DHCP request can go out before the bridge is actually forwarding and
        # the host boots with no lease.
        ConfigureWithoutCarrier = true;
      };
      linkConfig.RequiredForOnline = "routable";
      dhcpV4Config.UseDNS = true;
    };
  };

  # br0 is a LAN interface, not a trusted one — the guest hangs off it. The
  # fleet default firewall (modules/nixos/common.nix) stays on; only SSH is
  # open, inherited from common.nix's openssh.
  networking.firewall.trustedInterfaces = [ ];

  # ── VFIO passthrough ────────────────────────────────────────────────────────
  # Bound by vendor:device ID, not bus address — addresses have been observed to
  # shift across reboots on this board. See modules/nixos/vfio.nix.
  #
  # Verified IOMMU grouping on this machine:
  #   group 1: 1b21:1166 (ASM1166 SATA, 01:00.0) + 1b21:1042 (ASM1042 USB3, 02:00.0)
  #            — both endpoints share the group, so they go together whether or
  #            not we want the USB3 card. Convenient: the Unraid licensing flash
  #            drive lives on it, and the license is tied to the USB GUID, so it
  #            has to be a physical passthrough anyway.
  #   group 9: 1b21:1064 (ASM1064 SATA, 03:00.0) — isolated.
  #
  # Onboard SATA (00:1f.2, group 8) is deliberately ABSENT: it shares a group
  # with the LPC bridge, and it is where the host's own root disk lives.
  homelab.vfio = {
    enable = true;
    cpuVendor = "intel";
    pciIds = [
      "1b21:1166" # ASM1166 6-port SATA — array + cache + fastservices. Permanent.
      "1b21:1042" # ASM1042 USB3 — same IOMMU group as the above; carries the Unraid licence key.
      # TEMPORARY. The ASM1064 comes back to the host once the Docker workloads
      # migrate off Unraid; at that point delete this one line and rebuild.
      # Nothing else in the config references it.
      "1b21:1064" # ASM1064 4-port SATA
    ];
  };

  # ── libvirt / KVM ───────────────────────────────────────────────────────────
  # The Unraid guest is defined by hosts/tower-hv/unraid-guest.xml, which is
  # `virsh define`d by hand rather than generated. libvirt is stateful and the
  # whole point of this phase is to hand-edit passthrough while experimenting —
  # a declaratively-managed domain would fight that.
  virtualisation.libvirtd = {
    enable = true;

    # Do NOT auto-start guests during evaluation. A host that boots straight
    # into launching a storage guest is a host you cannot safely reboot to
    # debug. Flip to "start" once passthrough is proven.
    onBoot = "ignore";

    # "shutdown" sends ACPI and waits, rather than the default "suspend".
    # Suspending a guest that owns physical SATA controllers mid-array-write is
    # how you get an unclean array; Unraid needs a real shutdown so it can stop
    # the array and unmount cleanly.
    onShutdown = "shutdown";

    qemu = {
      package = pkgs.qemu_kvm;
      runAsRoot = true;

      # Deliberately NO `ovmf` block. As of nixpkgs 26.05 the
      # virtualisation.libvirtd.qemu.ovmf submodule is removed — setting any of
      # its attributes trips an assertion — because every OVMF image QEMU ships
      # is now available by default. That is what lets unraid-guest.xml use
      # libvirt's `firmware='efi'` autoselection instead of a hardcoded
      # /nix/store loader path, which would break on the next nixpkgs bump.
      #
      # No vTPM either: this board has no TPM 2.0 and Unraid does not want one.
      # (swtpm.enable defaults to false; not set here to keep the assertion
      # surface small.)
    };
  };

  # Lets libvirt attach guest interfaces to br0 via the qemu bridge helper.
  virtualisation.libvirtd.allowedBridges = [ "br0" ];

  # `libvirtd` for virsh without sudo; `kvm` for /dev/kvm. Merges with the
  # fleet-default groups in modules/nixos/common.nix rather than replacing them.
  users.users.z.extraGroups = [ "libvirtd" "kvm" ];

  environment.systemPackages = with pkgs; [
    virt-manager   # `virt-manager -c qemu+ssh://z@tower-hv.internal/system` from serenity
    virt-viewer
    pciutils       # lspci -nnk — the primary "did vfio actually bind?" check
    usbutils       # lsusb -t — confirm the licence key landed on the ASM1042
    smartmontools  # SMART through passthrough is a thing to verify explicitly
    freeipmi       # ipmiconsole/ipmipower, for driving this box's own BMC
    tmux
  ];

  # ── UPS ─────────────────────────────────────────────────────────────────────
  # Intentionally no NUT config on this host yet.
  #
  # Tower's rack UPS is currently USB-attached to the Unraid box, which serves
  # it as `ups@tower.internal` — memory-alpha is a secondary
  # (modules/nixos/nut-client.nix). Virtualizing Tower breaks that: the UPS USB
  # lands on the host, so the guest can no longer be the NUT server, and this
  # host — which physically holds every disk — would have no UPS awareness and
  # get hard-cut mid-parity-check.
  #
  # The agreed fix is to move the UPS to memory-alpha and make it the NUT
  # server, with Tower a client. That is better than making *this* host the
  # server, because then Tower is a client whether it is running bare-metal
  # Unraid or this hypervisor — the arrangement becomes identical in both states
  # and stops being something the fallback can break. It also moves UPS duty off
  # the machine that is about to be rebooted fifty times.
  #
  # That work is a separate `[memory-alpha]` change plus a physical cable move.
  # Until it lands, bare-metal Unraid keeps serving its UPS exactly as today —
  # nothing is broken by omitting it here — but this host is unprotected, so
  # treat evaluation as supervised, attended work.

  # ── sops-nix ────────────────────────────────────────────────────────────────
  # Uses the host's SSH ed25519 key as the age identity. After first boot:
  #   ssh-to-age < /etc/ssh/ssh_host_ed25519_key.pub
  # then replace the tower-hv placeholder in .sops.yaml, add *tower-hv to its
  # creation rule, and run: sops updatekeys secrets/tower-hv.yaml
  sops = lib.mkIf hasSops {
    defaultSopsFile = ../../secrets/tower-hv.yaml;
    age.sshKeyPaths = [ "/etc/ssh/ssh_host_ed25519_key" ];
    secrets."z/hashedPassword".neededForUsers = true;
  };

  users.users.z.hashedPasswordFile =
    lib.mkIf hasSops config.sops.secrets."z/hashedPassword".path;

  # ── home-manager ──────────────────────────────────────────────────────────
  home-manager = {
    useGlobalPkgs = true;
    useUserPackages = true;
    users.z = import ./home.nix;
  };

  # Internet-facing? No — LAN only. Traefik/LE machinery lives on memory-alpha;
  # tower-hv does not import it.
  system.stateVersion = "26.05";
}
