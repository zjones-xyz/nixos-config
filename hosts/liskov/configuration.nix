{ config, pkgs, lib, ... }:

let
  # secrets/liskov.yaml does not exist in the repo yet — it must be created by
  # Zoe once the host has booted and its age key is known (see DEPLOY.md
  # §11). Gated on the file's presence so the closure evaluates cleanly until
  # then, and activates automatically once the encrypted file is committed.
  # Same pattern as hosts/pegasus/configuration.nix.
  hasSops = builtins.pathExists ../../secrets/liskov.yaml;

  # TODO(install): confirm with `ip -br link` on the machine. Survey 2026-08-06
  # confirmed two Intel NICs, both isolated in their own IOMMU groups:
  #   00:19.0  82579LM  (group 2)  — expected eno1, the host/br0 NIC
  #   04:00.0  82574L   (group 10) — expected eno2/enp4s0
  # Predictable naming usually lands them as eno1/eno2, but the firmware's
  # onboard index is not guaranteed. This is the ONLY place the name appears.
  #
  # Because 04:00.0 is isolated, passing it whole to the guest instead of using
  # br0 is a real option. Not taken: with a bridge the guest presents the
  # bare-metal MAC verbatim, so the DHCP reservation and tower.internal resolve
  # identically whether the machine is virtualized or booted bare metal. NIC
  # passthrough would tie the guest to the 82574L's own MAC and make the two
  # states differ — which is exactly what the fallback guarantee forbids.
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
  #
  # "liskov" after Barbara Liskov, joining hopper and hamilton. The substitution
  # principle is this host's actual contract: a subtype must be usable anywhere
  # the base type is expected — which is precisely what a hypervisor promises the
  # guest. Unraid must not be able to tell it is not on bare metal. Every design
  # decision below that looks fussy (controllers passed whole rather than as
  # virtual disks, a real bridge rather than NAT, the licence key as a real
  # physical USB device rather than an emulated image) is in service of holding
  # up that substitution.
  networking.hostName = "liskov";
  networking.domain = "internal";

  # ── Boot ────────────────────────────────────────────────────────────────────
  # systemd-boot, matching memory-alpha/pegasus. Requires the board to be in
  # UEFI (or Dual) boot mode — see DEPLOY.md § Bootloader for the legacy/GRUB
  # alternative and why you might deliberately choose it. hosts/liskov/disko.nix
  # provisions a BIOS boot partition either way so switching does not mean
  # repartitioning.
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  # Keep the boot menu short, and keep the ESP from filling. disko.nix gives /boot
  # 1 GiB, and a systemd initrd generation runs ~70-95 MB, so ten would sit
  # uncomfortably close to full. Five is ample for a host whose rollback story is
  # "boot the Unraid flash instead" — and a cluttered boot menu is one more thing
  # to get wrong at 3am.
  boot.loader.systemd-boot.configurationLimit = 5;

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
  # NO systemd.services."serial-getty@ttyS1" block here, deliberately.
  #
  # Writing one looks harmless and is actively harmful: the name is an *instance*,
  # not an upstream unit, so NixOS emits a standalone
  # /etc/systemd/system/serial-getty@ttyS1.service. systemd resolves an instance
  # to an exact-name file first and only falls back to serial-getty@.service if
  # none exists — so the upstream template is never loaded and everything in it is
  # silently lost: Type=idle, BindsTo=dev-%i.device, After=systemd-user-sessions
  # .service, TTYPath/TTYReset/TTYVHangup, UtmpIdentifier. On the one console that
  # has to work to type a LUKS passphrase, that means the prompt can appear before
  # logins are permitted (pam_nologin), interleaves with boot output, and — with an
  # explicit Restart=always and no BindsTo — restart-loops into `failed` if
  # /dev/ttyS1 does not exist, which is exactly what happens if the BIOS puts SoL
  # on COM1 instead.
  #
  # None of it is needed: systemd-getty-generator already instantiates
  # serial-getty@ttyS1 from the console=ttyS1,115200n8 kernel parameter above.

  # ── LUKS ────────────────────────────────────────────────────────────────────
  # The root disk is encrypted from install time (see hosts/liskov/disko.nix
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
  # adjust. Note boot.initrd.systemd.enable is ALREADY true here — it is the
  # 26.05 default — so unlike pegasus there is nothing to turn on; add "e1000e" to
  # boot.initrd.availableKernelModules, generate the dedicated initrd host key
  # (`ssh-keygen -t ed25519 -N "" -f /etc/secrets/initrd/ssh_host_ed25519_key`),
  # and add an `unlock-liskov` alias to hosts/serenity/home.nix. The
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
    #
    # NOTE for the DHCP reservation: br0 does NOT inherit eno1's MAC. systemd's
    # 99-default.link applies MACAddressPolicy=persistent, giving the bridge its
    # own generated stable address, and the kernel then leaves it alone. That is
    # what we want — the *guest* uses bare-metal Tower's MAC, so an inherited one
    # would be a duplicate on the LAN — but it means liskov's own reservation must
    # be keyed on br0's MAC, read off the machine after first boot, not on eno1's.
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
  # Surveyed on the machine 2026-08-06 (scripts/iommu-survey.sh). IOMMU is on by
  # default on this kernel — intel_iommu=on is NOT in Unraid's cmdline and the
  # groups populate anyway.
  #
  #   group 1 (4 devices): 00:01.0 + 00:01.1 CPU PCIe root ports,
  #                        01:00.0 ASM1166 SATA, 02:00.0 ASM1042 USB3
  #   group 9:             03:00.0 ASM1064 SATA — isolated
  #   group 8 (3 devices): 00:1f.0 LPC + 00:1f.2 onboard SATA + 00:1f.3 SMBus
  #
  # The mechanism, which explains all of it: **the Ivy Bridge CPU root ports
  # (00:01.x) do not advertise ACS, so everything behind them lands in one
  # group. The PCH root ports (00:1c.x) do, so devices behind them are
  # isolated.** ASM1166 and ASM1042 sit in CPU slots; ASM1064 sits in a PCH
  # slot. That is the whole story.
  #
  # Consequences worth not re-deriving later:
  #   - The two root-port bridges in group 1 do NOT block passthrough. VFIO's
  #     viability check only requires the *endpoints* to be bound to vfio-pci;
  #     bridges are tolerated.
  #   - **Moving the ASM1042 to a PCH slot should isolate it — worth doing.**
  #     Four PCIe slots, visually confirmed identical: two CPU-attached
  #     (ASM1166, ASM1042), one PCH-attached (ASM1064), one free. Only two PCH
  #     root ports appear because Supermicro hides ports with nothing behind
  #     them (the C204 has eight), so the free slot's port should appear once
  #     populated.
  #
  #     (The 00:1e.0 82801 PCI bridge in group 7 is NOT evidence of a legacy PCI
  #     slot — it carries the WPCM450 BMC's onboard Matrox video on an internal
  #     bus. Noted because it misled one review pass.)
  #
  #     Move the ASM1042 to the free PCH slot and it lands behind its own root
  #     port, in its own group, and the HOST can keep it. Group 1 then reduces
  #     to the CPU root ports plus the ASM1166 alone: a single endpoint, cleanly
  #     passable, no rider.
  #
  #     Do NOT instead swap the ASM1042 and ASM1064. That would drop the
  #     ASM1064 into group 1 with the ASM1166 and make it impossible to hand
  #     back to the host later without also surrendering the array controller.
  #
  #     UNVERIFIED until re-surveyed: this predicts an empty root port appears
  #     once the slot is populated. Re-run scripts/iommu-survey.sh after the
  #     move. If it isolates, delete "1b21:1042" from pciIds below and drop the
  #     matching <hostdev> from unraid-guest.xml.
  #   - The licence key does NOT depend on the ASM1042. Both onboard EHCI
  #     controllers are isolated, and the survey mapped them to physical ports:
  #
  #       00:1a.0  group 3  — the INTERNAL header. Also carries the BMC's
  #                           virtual HID (0557:2221 Winbond/Nuvoton Hermon,
  #                           the WPCM450 that also provides the Matrox G200eW
  #                           in group 7).
  #       00:1d.0  group 6  — carries the Unraid boot flash today. Clean.
  #
  #     ⚠ NEVER pass 00:1a.0 through as a PCI device. Handing that controller to
  #     the guest takes IPMI's virtual keyboard and mouse away from the host —
  #     the remote-hands path this whole deployment depends on, and the only way
  #     to type a LUKS passphrase until initrd SSH unlock exists.
  #
  #     This does NOT rule the internal header out for the licence key. A
  #     <hostdev type='usb'> entry forwards one device while the host keeps the
  #     controller, so the BMC HID is unaffected. Internal is in fact the better
  #     home for a licence dongle — inside the case, not bumpable.
  #     See hosts/liskov/unraid-guest.xml and DEPLOY.md § 13.
  #
  # Onboard SATA (00:1f.2, group 8) is deliberately ABSENT: it shares a group
  # with the LPC bridge and SMBus, and it is where the host's own root disk lives.
  homelab.vfio = {
    enable = true;
    cpuVendor = "intel";
    pciIds = [
      "1b21:1166" # ASM1166 6-port SATA — array + cache + fastservices. Permanent.
      "1b21:1042" # ASM1042 USB3 — rides along: same IOMMU group as the ASM1166 (CPU
                  #             root ports lack ACS). NOT needed for the licence key.
      # TEMPORARY. The ASM1064 comes back to the host once the Docker workloads
      # migrate off Unraid; at that point delete this one line and rebuild.
      # Nothing else in the config references it.
      "1b21:1064" # ASM1064 4-port SATA
    ];
  };

  # ── libvirt / KVM ───────────────────────────────────────────────────────────
  # The Unraid guest is defined by hosts/liskov/unraid-guest.xml, which is
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
    virt-manager   # `virt-manager -c qemu+ssh://z@liskov.internal/system` from serenity
    virt-viewer
    pciutils       # lspci -nnk — the primary "did vfio actually bind?" check
    usbutils       # lsusb -t — confirm the licence key reached the guest
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
  # then replace the liskov placeholder in .sops.yaml, add *liskov to its
  # creation rule, and run: sops updatekeys secrets/liskov.yaml
  sops = lib.mkIf hasSops {
    defaultSopsFile = ../../secrets/liskov.yaml;
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
  # liskov does not import it.
  system.stateVersion = "26.05";
}
