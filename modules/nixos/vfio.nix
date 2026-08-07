{ config, pkgs, lib, ... }:

let
  cfg = config.homelab.vfio;

  idList = lib.concatStringsSep "," cfg.pciIds;

  # vvvv:dddd — four lowercase hex digits, a colon, four more. Bad IDs are the
  # single nastiest failure here: vfio-pci silently binds nothing, `lspci -nnk`
  # still shows ahci on the controllers, and the symptom is indistinguishable
  # from "the card isn't seated" or the X9SCM BIOS quirk (see hosts/liskov/DEPLOY.md).
  # Catch typos at eval time instead of at 2am in front of the machine.
  idPattern = "[0-9a-f]{4}:[0-9a-f]{4}";
  badIds = lib.filter (id: builtins.match idPattern id == null) cfg.pciIds;
in
{
  options.homelab.vfio = {
    enable = lib.mkEnableOption ''
      VFIO PCI passthrough: bind the listed devices to vfio-pci at boot so they
      can be handed whole to a KVM guest
    '';

    cpuVendor = lib.mkOption {
      type = lib.types.enum [ "intel" "amd" ];
      default = "intel";
      description = ''
        Which IOMMU kernel parameter to set. Intel needs `intel_iommu=on`, AMD
        needs `amd_iommu=on`; the wrong one is silently ignored, which looks
        exactly like VT-d/AMD-Vi being disabled in firmware.
      '';
    };

    pciIds = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "1b21:1166" "1b21:1042" ];
      description = ''
        PCI vendor:device IDs to bind to vfio-pci, as printed by `lspci -nn`.

        Deliberately IDs and not bus addresses: addresses shift across reboots
        on some boards (confirmed on the X9SCM), so a `0000:01:00.0`-style
        binding silently starts capturing the wrong device — or nothing.

        The trade-off is that an ID binds *every* card with that vendor:device.
        That is fine when the identical-model card is meant to be passed through
        wholesale, and dangerous if the host needs one of them: check
        `lspci -nn | grep <id>` returns only the cards you intend to give away.
      '';
    };

    softdepDrivers = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ "ahci" "xhci_pci" "xhci_hcd" "nvme" ];
      description = ''
        Drivers that must not claim a passed-through device before vfio-pci does.
        Each gets a `softdep <drv> pre: vfio-pci` line.

        This is the mechanism that actually closes the race — see the comment on
        boot.extraModprobeConfig below. It therefore has to name the competing
        driver for *every* class of device in pciIds, not just storage: a USB3
        controller is claimed by xhci_pci, an NVMe controller by nvme, and a
        SATA HBA by ahci. Missing one means that device silently stays bound to
        its normal driver and its IOMMU group becomes unusable.
      '';
    };

    passthroughIsolatedOnly = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Purely advisory flag recorded for documentation: set false only if you
        have knowingly accepted passing a device whose IOMMU group contains
        host-critical siblings. Nothing reads it — it exists so the intent is
        greppable next to the ID list.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = badIds == [ ];
        message =
          "homelab.vfio.pciIds: not vendor:device form (expected e.g. \"1b21:1166\"): "
          + lib.concatStringsSep ", " badIds;
      }
      {
        assertion = cfg.pciIds != [ ];
        message = "homelab.vfio.enable is true but homelab.vfio.pciIds is empty — nothing would be bound.";
      }
    ];

    boot.kernelParams = [
      # IOMMU itself. Without this the groups never form and vfio-pci has
      # nothing to attach to.
      (if cfg.cpuVendor == "intel" then "intel_iommu=on" else "amd_iommu=on")
      # Pass-through mode: identity-map host devices rather than translating
      # every DMA. Meaningfully cheaper for the devices the *host* keeps, and
      # has no effect on the ones handed to the guest.
      "iommu=pt"
      "vfio-pci.ids=${idList}"
    ];

    # Load vfio-pci early. Necessary, but NOT by itself sufficient — see the
    # softdep note below, which is what actually closes the race.
    #
    # `vfio-pci.ids=` on the kernel command line rather than an options line in
    # modprobe.d: the cmdline is parsed by the module itself at load time, is
    # equally honoured by kmod and by libvirt, and does not depend on
    # modprobe.d file ordering. (NOT because modprobe.d is unreadable early —
    # NixOS copies /etc/modprobe.d into the initrd, which is exactly why the
    # softdep below works. `options vfio-pci ids=…` there would be read too;
    # the cmdline is just the more robust place to say it.)
    #
    # NOTE: vfio_virqfd must NOT be listed. It was folded into vfio_pci in Linux
    # 6.2 and no longer exists as a separate module; every pre-6.2 guide on the
    # internet still tells you to load it, and on a 26.05 kernel that is a
    # missing-module error at initrd build.
    boot.initrd.kernelModules = [ "vfio_pci" "vfio_iommu_type1" "vfio" ];

    # ── The part that actually works ────────────────────────────────────────
    # A common claim, which this module used to repeat, is that listing vfio_pci
    # in boot.initrd.kernelModules force-loads it before the storage drivers and
    # therefore wins the race. **That is only true of the scripted initrd.**
    # boot.initrd.systemd.enable defaults to true on 26.05, and in the systemd
    # initrd boot.initrd.kernelModules becomes /etc/modules-load.d/nixos.conf,
    # loaded by systemd-modules-load.service — which has no ordering relationship
    # to systemd-udevd or systemd-udev-trigger. Both are DefaultDependencies=no,
    # Before=sysinit.target, and nothing sequences them against each other. So
    # udev coldplug can bind the normal driver first.
    #
    # The softdep is what genuinely closes it: NixOS copies /etc/modprobe.d into
    # the systemd initrd, and libkmod honours softdep for udev-driven autoloads.
    #
    # It must name the competing driver for every device class in pciIds. Note
    # boot.initrd.includeDefaultModules (default true) unconditionally adds
    # xhci_pci, xhci_hcd, ahci and nvme to the initrd regardless of what
    # hardware-configuration.nix lists, so those drivers ARE present and WILL be
    # autoloaded — omitting one from this list is a silent passthrough failure
    # that looks exactly like a bad device ID.
    boot.extraModprobeConfig = lib.concatMapStrings
      (drv: "softdep ${drv} pre: vfio-pci\n") cfg.softdepDrivers;
  };
}
