{
  description = "zjones homelab NixOS configuration";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";

    home-manager = {
      url = "github:nix-community/home-manager/release-26.05";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    sops-nix = {
      url = "github:Mic92/sops-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # Hardware profiles for the Raspberry Pis. Both hopper (Pi 4) and hamilton
    # (Pi 3) use these profiles plus nixpkgs' generic aarch64 sd-image module,
    # which boots via u-boot on the mainline kernel — and the mainline kernel
    # is in cache.nixos.org, so the images build without compiling a kernel.
    # (We deliberately avoid raspberry-pi-nix: its downstream kernel isn't
    # cached, forcing a multi-hour emulated compile on every bump.)
    nixos-hardware.url = "github:NixOS/nixos-hardware";

    # nix-darwin for the Mac (Serenity). nix-darwin uses release branches that
    # must match the nixpkgs release — nix-darwin-26.05 pairs with nixpkgs 26.05
    # (master is a newer release and is rejected by nix-darwin's release check).
    nix-darwin = {
      url = "github:nix-darwin/nix-darwin/nix-darwin-26.05";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # Declarative KDE Plasma via Home Manager (used on pegasus).
    plasma-manager = {
      url = "github:nix-community/plasma-manager";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.home-manager.follows = "home-manager";
    };

    # Claude Desktop (used on pegasus). Anthropic shipped an official Linux
    # beta (.deb, own apt repo) on 2026-06-30 but hasn't reached nixpkgs yet
    # (too recent). This flake repackages that *official* .deb for Nix as of
    # its v3.0.0 — not the older community approach of patching the Windows/
    # macOS build to run on Linux. See hosts/pegasus/DECISIONS.md.
    # git+https rather than github: — this session's GitHub access is
    # scoped to zjones-xyz/nixos-config only, so the github: tarball-API
    # fetch 403s here (though it works fine anywhere with normal GitHub
    # access, e.g. on pegasus itself). git+https uses plain git protocol
    # instead, unaffected either way — see .claude/hooks/flake-check-sandboxed.sh
    # for the same workaround applied to the other inputs.
    claude-desktop-debian = {
      url = "git+https://github.com/aaddrick/claude-desktop-debian.git";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, home-manager, sops-nix, nixos-hardware, nix-darwin, plasma-manager, claude-desktop-debian, ... }:
  let
    lib = nixpkgs.lib;
  in
  {
    nixosConfigurations = {
      memory-alpha = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        specialArgs = { inherit self; };
        modules = [
          ./hosts/memory-alpha/configuration.nix
          home-manager.nixosModules.home-manager
          sops-nix.nixosModules.sops
        ];
      };

      # pegasus — AM4 Ryzen + RTX 4070 workstation: gaming desktop (Plasma 6 /
      # Wayland) and the primary GPU inference endpoint (ollama + Olla router).
      # Single NVMe, installed via hosts/pegasus/disko.nix (2026-07-11).
      pegasus = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        specialArgs = { inherit self; };
        modules = [
          ./hosts/pegasus/configuration.nix
          home-manager.nixosModules.home-manager
          sops-nix.nixosModules.sops
          {
            # Make plasma-manager's HM options available to hosts/pegasus/home.nix.
            home-manager.sharedModules = [ plasma-manager.homeModules.plasma-manager ];
            # claude-desktop-debian has no HM module, just a package — pass it
            # through directly rather than adding it as a NixOS-level overlay.
            home-manager.extraSpecialArgs = {
              claudeDesktop = claude-desktop-debian.packages.x86_64-linux.claude-desktop-fhs;
            };
          }
        ];
      };

      # liskov — Supermicro X9SCM / Xeon E3-1230 v2. Minimal hypervisor whose
      # only job (for now) is running the existing Unraid 7.3.2 install as a KVM
      # guest with its SATA controllers passed through, so the approach can be
      # evaluated before any workload moves.
      #
      # NOT named "tower": tower.internal stays pointed at the Unraid instance,
      # which is what memory-alpha's NFS mounts and NUT client resolve, and what
      # the machine *is* when booted bare metal. See hosts/liskov/DEPLOY.md.
      #
      # Installed via hosts/liskov/disko.nix (LUKS root on the Kingston 120GB,
      # which must be on an ONBOARD SATA port — the add-in controllers are bound
      # to vfio-pci and handed to the guest).
      liskov = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        specialArgs = { inherit self; };
        modules = [
          ./hosts/liskov/configuration.nix
          home-manager.nixosModules.home-manager
          sops-nix.nixosModules.sops
        ];
      };

      # liskov-vm — the same config with the real machine's hardware stripped
      # out, so it can be booted under plain QEMU on the CachyOS desktop:
      #   nix run .#nixosConfigurations.liskov-vm.config.system.build.vm
      #
      # Exists because everything in liskov that is cheap to get wrong
      # (networkd bridge, libvirtd, users, sops gating, serial console) is
      # expensive to debug on a machine whose disks are a live Unraid array.
      # Proves the config boots and the services come up BEFORE Tower is touched.
      #
      # It cannot prove passthrough — there is no ASM1166 in a VM. What it
      # catches is everything else.
      liskov-vm = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        specialArgs = { inherit self; };
        modules = [
          ./hosts/liskov/configuration.nix
          home-manager.nixosModules.home-manager
          sops-nix.nixosModules.sops
          ({ lib, modulesPath, ... }: {
            # The real hardware-configuration.nix points root at a LUKS mapper
            # device with a placeholder UUID; keeping it would hang the VM in
            # the initrd waiting for a device that will never appear.
            disabledModules = [ ./hosts/liskov/hardware-configuration.nix ];
            imports = [ (modulesPath + "/virtualisation/qemu-vm.nix") ];

            nixpkgs.hostPlatform = "x86_64-linux";
            boot.initrd.luks.devices = lib.mkForce { };
            boot.loader.systemd-boot.enable = lib.mkForce false;
            boot.loader.efi.canTouchEfiVariables = lib.mkForce false;

            # No ASM1166/ASM1042/ASM1064 to bind, and vfio-pci.ids= against a
            # device that isn't present is a confusing no-op rather than an error.
            homelab.vfio.enable = lib.mkForce false;

            # eno1 does not exist in the VM, so the bridge would never get a
            # carrier and network-online.target would block until timeout. Hand
            # networking back to qemu-vm's own scripted DHCP.
            #
            # systemd.network.enable must go off too, not just the netdev and
            # network definitions: leaving it on alongside useDHCP with networkd
            # disabled lets networkd and dhcpcd both manage the same interface,
            # which nixpkgs warns about and which loses networking outright.
            systemd.network.enable = lib.mkForce false;
            systemd.network.netdevs = lib.mkForce { };
            systemd.network.networks = lib.mkForce { };
            networking.useNetworkd = lib.mkForce false;
            networking.useDHCP = lib.mkForce true;

            # A QEMU guest has only ttyS0; liskov's BMC puts Serial-over-LAN on
            # COM2 (ttyS1). Inheriting ttyS1 meant the VM registered a console
            # on a UART that does not exist and systemd bound the login prompt
            # to a device that never appeared — it booted correctly in ~5s and
            # offered no way in. Scalar option, so mkForce works; a list entry
            # could not have been removed.
            homelab.serialConsole.device = lib.mkForce "ttyS0,115200n8";

            # Console logins for the throwaway VM only.
            #
            # Without this the smoke test proves nothing past "it booted": the
            # real host sets no password at all (z's comes from sops, and
            # secrets/liskov.yaml does not exist yet; root never gets one), so
            # both accounts land in /etc/shadow locked and the VM boots to a
            # login prompt nobody can get past. There is no way to run `passwd`
            # either, because that would require logging in first.
            #
            # Scoped to this module list, so it cannot reach the real liskov.
            # Not a secret: it grants a shell on a qcow2 you just built locally,
            # behind qemu user-mode networking with no inbound path.
            users.users.root.initialPassword = "liskov";
            users.users.z.initialPassword = "liskov";

            virtualisation = {
              memorySize = 2048;
              cores = 2;
              diskSize = 8192;
              graphics = false;  # serial console, matching how the real host is driven
            };
          })
        ];
      };

      # hopper — Raspberry Pi 4, network-core node. Uses nixos-hardware's rpi-4
      # profile plus nixpkgs' generic sd-image-aarch64 builder (mainline kernel,
      # cached — see the nixos-hardware input comment above).
      #
      # Bootstrap: build the SD image on memory-alpha (aarch64 via binfmt) and
      # flash it — boots straight into this config. See hosts/hopper/DEPLOY.md.
      #   nix build .#nixosConfigurations.hopper.config.system.build.sdImage
      # Routine deploys, with memory-alpha as the aarch64 build host:
      #   nixos-rebuild switch --flake .#hopper \
      #     --target-host z@hopper.internal \
      #     --build-host z@memory-alpha.internal --use-remote-sudo
      hopper = nixpkgs.lib.nixosSystem {
        system = "aarch64-linux";
        specialArgs = { inherit self; };
        modules = [
          nixos-hardware.nixosModules.raspberry-pi-4
          "${nixpkgs}/nixos/modules/installer/sd-card/sd-image-aarch64.nix"
          ./hosts/hopper/configuration.nix
          home-manager.nixosModules.home-manager
          sops-nix.nixosModules.sops
        ];
      };

      # hamilton — Raspberry Pi 3 (bcm2837), backup AdGuard/Unbound resolver.
      # Same approach as hopper: nixos-hardware's rpi-3 profile plus nixpkgs'
      # sd-image-aarch64 builder (SD-card boot).
      #
      # Bootstrap: build the SD image on memory-alpha (aarch64 via binfmt) and
      # flash it — boots straight into this config. See hosts/hamilton/DEPLOY.md.
      #   nix build .#nixosConfigurations.hamilton.config.system.build.sdImage
      # Routine deploys, with memory-alpha as the aarch64 build host:
      #   nixos-rebuild switch --flake .#hamilton \
      #     --target-host z@hamilton.internal \
      #     --build-host z@memory-alpha.internal --use-remote-sudo
      hamilton = nixpkgs.lib.nixosSystem {
        system = "aarch64-linux";
        specialArgs = { inherit self; };
        modules = [
          nixos-hardware.nixosModules.raspberry-pi-3
          "${nixpkgs}/nixos/modules/installer/sd-card/sd-image-aarch64.nix"
          ./hosts/hamilton/configuration.nix
          home-manager.nixosModules.home-manager
          sops-nix.nixosModules.sops
        ];
      };
    };

    # ── Darwin (macOS) ──────────────────────────────────────────────────────
    # Serenity — Zoe's Mac. Shares modules/home/common.nix with the Linux hosts
    # via Home Manager. Build/activate on the Mac with:
    #   nix run nix-darwin -- switch --flake .#serenity
    # nix.enable = false in the host config so it coexists with Determinate Nix.
    darwinConfigurations.serenity = nix-darwin.lib.darwinSystem {
      system = "aarch64-darwin";
      modules = [
        ./hosts/serenity/configuration.nix
        home-manager.darwinModules.home-manager
        {
          home-manager.useGlobalPkgs = true;
          home-manager.useUserPackages = true;
          # Back up pre-existing dotfiles HM would otherwise refuse to clobber
          # (e.g. the Mac's hand-written ~/.zshrc → ~/.zshrc.before-nix-darwin).
          home-manager.backupFileExtension = "before-nix-darwin";
          home-manager.users.z = import ./hosts/serenity/home.nix;
        }
      ];
    };

    # ── Checks ────────────────────────────────────────────────────────────────
    # Asserts the liskov invariants that are cheap to break in a rebuild and
    # expensive to discover in front of the machine — a wrong vfio binding means
    # either the guest gets nothing or the HOST loses its own root disk.
    #
    # Written as eval-time assertions on purpose. CI runs `nix flake check
    # --no-build`, which evaluates check derivations without building them, so a
    # `throw` here fires in the existing workflow with no extra step and no need
    # for KVM on the runner. The derivation itself is a formality.
    checks.x86_64-linux =
      let
        pkgs = nixpkgs.legacyPackages.x86_64-linux;
        cfg = self.nixosConfigurations.liskov.config;

        params = cfg.boot.kernelParams;
        initrdMods = cfg.boot.initrd.kernelModules;
        vfioIds = cfg.homelab.vfio.pciIds;

        hasParam = p: lib.elem p params;

        # Parse the ids actually on the kernel command line, rather than reading
        # homelab.vfio.pciIds back. Checking the option against a parameter built
        # from that same option is true by construction and catches nothing; the
        # scenario worth guarding — a hand-written boot.kernelParams entry, or an
        # mkForce that drops one — only shows up in the effective value.
        #
        # ALL matching parameters, not just the first: boot.kernelParams is a
        # list and nothing stops a second `vfio-pci.ids=` being appended
        # elsewhere in the config. Taking only the first would let exactly the
        # dangerous case — someone adding an Intel id by hand — slip past.
        idsParams = lib.filter (lib.hasPrefix "vfio-pci.ids=") params;
        effectiveIds = lib.filter (s: s != "")
          (lib.concatMap
            (p: lib.splitString "," (lib.removePrefix "vfio-pci.ids=" p))
            idsParams);

        require = cond: msg: lib.optional (!cond) msg;

        failures = lib.flatten [
          (require (cfg.networking.hostName == "liskov")
            "hostName is '${cfg.networking.hostName}', expected 'liskov'. tower.internal must keep resolving to the Unraid instance — memory-alpha's NFS mounts and NUT client depend on it, and it is what the machine is when booted bare metal.")

          (require (hasParam "intel_iommu=on")
            "boot.kernelParams is missing intel_iommu=on — IOMMU groups never form and vfio-pci binds nothing.")
          (require (hasParam "iommu=pt")
            "boot.kernelParams is missing iommu=pt.")
          (require (idsParams != [ ])
            "boot.kernelParams has no vfio-pci.ids= entry — the controllers would stay bound to their normal drivers.")
          (require (lib.length idsParams <= 1)
            "boot.kernelParams has more than one vfio-pci.ids= entry (${toString (lib.length idsParams)}). Which one the kernel honours is not something to leave to chance — merge them into homelab.vfio.pciIds.")
          (require (lib.all (id: lib.elem id effectiveIds) vfioIds)
            "vfio-pci.ids= on the kernel command line does not carry every id in homelab.vfio.pciIds — something overrode boot.kernelParams.")

          (require (lib.elem "vfio_pci" initrdMods)
            "vfio_pci is not in boot.initrd.kernelModules — ahci will claim the SATA controllers first and passthrough silently fails.")
          (require (lib.elem "vfio_iommu_type1" initrdMods)
            "vfio_iommu_type1 is not in boot.initrd.kernelModules.")
          # Folded into vfio_pci in Linux 6.2. Every pre-6.2 guide still tells
          # you to load it; on a 26.05 kernel that is a missing-module error.
          (require (!lib.elem "vfio_virqfd" initrdMods)
            "vfio_virqfd is listed in boot.initrd.kernelModules — it was merged into vfio_pci in Linux 6.2 and no longer exists.")

          # The onboard SATA controller and both NICs are Intel (8086:). Binding
          # one to vfio-pci takes the host's own root disk or its only network
          # path. Checked against the EFFECTIVE kernel parameter, not the option,
          # so a hand-written boot.kernelParams cannot slip past it.
          (require (!lib.any (lib.hasPrefix "8086:") effectiveIds)
            "vfio-pci.ids= contains an Intel (8086:) device. Onboard SATA shares an IOMMU group with the LPC bridge and holds the host root disk; the NICs carry br0. Never pass these through.")

          # Every device class in pciIds needs its competing driver named in
          # softdepDrivers, or udev coldplug can bind it first. The ASM1042 USB3
          # controller is the live example: its competitor is xhci_pci, not ahci.
          (require (lib.elem "ahci" cfg.homelab.vfio.softdepDrivers)
            "homelab.vfio.softdepDrivers is missing \"ahci\" — SATA controllers could be claimed before vfio-pci.")
          (require (lib.elem "xhci_pci" cfg.homelab.vfio.softdepDrivers)
            "homelab.vfio.softdepDrivers is missing \"xhci_pci\" — the ASM1042 USB3 controller could be claimed before vfio-pci, silently breaking IOMMU group 1.")

          (require cfg.virtualisation.libvirtd.enable
            "libvirtd is not enabled — there is nothing to run the guest.")
          (require (cfg.virtualisation.libvirtd.onShutdown == "shutdown")
            "libvirtd.onShutdown is not \"shutdown\". Suspending a guest that owns physical SATA controllers mid-write is how the array ends up unclean.")
          (require (cfg.systemd.network.netdevs ? "10-br0")
            "no br0 bridge defined — the guest could not present the same LAN identity as bare-metal Tower.")

          (require (lib.any (lib.hasPrefix "console=ttyS") params)
            "no serial console in boot.kernelParams — the LUKS passphrase prompt would be unreachable over IPMI Serial-over-LAN, which is the only unlock path until initrd SSH is wired up.")
        ];
      in
      {
        # The guest domain is hand-maintained XML that nothing else validates —
        # a malformed file surfaces only at `virsh define` time, on the machine,
        # which is the worst place to find out. This caught a real instance:
        # XML comments may not contain "--", and `virsh --connect` in the header
        # comment made the whole file unparseable from the day it was written.
        #
        # Not an eval-time assertion, since nix cannot parse XML — so this only
        # runs under `nix build`, which .github/workflows/nix-check.yml does
        # explicitly. `nix flake check --no-build` will NOT catch a regression.
        liskov-guest-xml = pkgs.runCommand "liskov-guest-xml-wellformed"
          { nativeBuildInputs = [ pkgs.libxml2 ]; }
          ''
            xmllint --noout ${./hosts/liskov/unraid-guest.xml}
            touch $out
          '';

        liskov-invariants =
          if failures == [ ]
          then pkgs.runCommand "liskov-invariants-ok" { } "touch $out"
          else throw ''
            liskov configuration invariants failed:
            ${lib.concatMapStringsSep "\n" (f: "  - ${f}") failures}
          '';
      };
  };
}
