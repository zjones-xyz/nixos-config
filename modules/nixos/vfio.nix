{ config, pkgs, lib, ... }:

let
  cfg = config.homelab.vfio;

  idList = lib.concatStringsSep "," cfg.pciIds;

  # vvvv:dddd — four lowercase hex digits, a colon, four more. Bad IDs are the
  # single nastiest failure here: vfio-pci silently binds nothing, `lspci -nnk`
  # still shows ahci on the controllers, and the symptom is indistinguishable
  # from "the card isn't seated" or the X9SCM BIOS quirk (see hosts/tower-hv/DEPLOY.md).
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

    # The load-bearing part. vfio-pci must claim these devices before any
    # regular driver probes them — for SATA HBAs the competitor is `ahci`, which
    # the initrd pulls in to find the root filesystem. Listing them in
    # initrd.kernelModules force-loads vfio-pci first, so by the time ahci
    # probes, the controllers are already spoken for.
    #
    # `vfio-pci.ids=` on the kernel command line rather than an options line in
    # modprobe.d: the cmdline is parsed by the module itself at load time and so
    # applies inside the initrd, whereas /etc/modprobe.d is a property of the
    # booted system and may not be consulted early enough.
    #
    # NOTE: vfio_virqfd must NOT be listed. It was folded into vfio_pci in Linux
    # 6.2 and no longer exists as a separate module; every pre-6.2 guide on the
    # internet still tells you to load it, and on a 26.05 kernel that is a
    # missing-module error at initrd build.
    boot.initrd.kernelModules = [ "vfio_pci" "vfio_iommu_type1" "vfio" ];

    # Belt and braces for the booted system, where module load order is not
    # under initrd's control (e.g. a controller hot-added later, or ahci being
    # loaded on demand). Redundant with the initrd ordering on a normal boot.
    boot.extraModprobeConfig = ''
      softdep ahci pre: vfio-pci
    '';
  };
}
