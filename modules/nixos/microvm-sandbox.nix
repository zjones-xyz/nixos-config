# ── Isolated agent dev-sandbox (microVM) ────────────────────────────────────
# Shared, parameterized guest module for the isolated coding-agent sandbox.
# See docs/microvm-sandbox/DECISIONS.md for the full design rationale (N1–N4,
# the memory model, store/volume layout, network approach). This file is
# Phase 1 scope only: skeleton module + boot. No agent user, no Docker, no
# containment denylist yet — those land in Phases 2–3. Phase 1's minimal
# networking (below) gets the guest online so its own gate ("outbound
# internet" + "nix build a trivial derivation") is checkable; it is NOT yet
# the brief's containment policy — nothing here blocks LAN/tailnet access.
# Phase 2 replaces the wide-open NAT below with the N2 denylist. Do not treat
# a Phase-1-only guest as safe from a network-isolation standpoint.
{ config, lib, pkgs, ... }:

let
  cfg = config.homelab.agentSandbox;
in
{
  options.homelab.agentSandbox = {
    enable = lib.mkEnableOption "isolated coding-agent dev-sandbox microVM";

    guestName = lib.mkOption {
      type = lib.types.str;
      description = ''
        Name for `microvm.vms.<name>` and the guest's hostname
        (`networking.hostName` defaults to this via microvm.nix's own
        `lib.mkDefault name`).
      '';
    };

    mem = lib.mkOption {
      type = lib.types.ints.positive;
      description = ''
        Flat guest RAM in MiB. Deliberately flat, not floor+ceiling — see
        DECISIONS.md's memory section for why virtio-mem hotplug growth was
        rejected in favor of balloon-only reclaim.
      '';
    };

    vcpu = lib.mkOption {
      type = lib.types.ints.positive;
      default = 4;
      description = "Guest vCPU count.";
    };

    balloon = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Enable virtio-balloon so the host can reclaim guest memory under pressure.";
    };

    deflateOnOOM = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Auto-deflate the balloon if the guest itself starts running low as a result.";
    };

    forwardedPort = lib.mkOption {
      type = lib.types.nullOr lib.types.port;
      default = null;
      description = ''
        Host TCP port forwarded to the guest's dev-server port
        (`guestDevPort`). Declared here so instances can reserve it now; the
        actual host->guest forward and firewall scoping is wired in Phase 2.
        null means "not wired yet".
      '';
    };

    guestDevPort = lib.mkOption {
      type = lib.types.port;
      default = 3000;
      description = "Port inside the guest that forwardedPort targets (Phase 2).";
    };

    storeVolumeDir = lib.mkOption {
      type = lib.types.path;
      description = ''
        Host directory, on its own persistent btrfs subvolume, holding the
        writable-store-overlay image (N1). NOT snapshotted by btrbk — pure
        build-artifact churn, not worth restoring.
      '';
    };

    stateVolumeDir = lib.mkOption {
      type = lib.types.path;
      description = ''
        Host directory, on its own persistent btrfs subvolume, holding the
        guest's `/persist` state image (N3: SSH host key / agent home /
        Docker data land here from Phase 3 on). This is what btrbk (Phase 5)
        snapshots for reset-after-the-agent-wrecks-it.
      '';
    };

    storeVolumeSizeMiB = lib.mkOption {
      type = lib.types.ints.positive;
      default = 65536; # 64 GiB
      description = "Size of the store-overlay image.";
    };

    stateVolumeSizeMiB = lib.mkOption {
      type = lib.types.ints.positive;
      default = 16384; # 16 GiB
      description = "Size of the /persist state image.";
    };

    interfaceId = lib.mkOption {
      type = lib.types.str;
      description = ''
        Host tap interface name for this guest. Must be <=15 characters
        (Linux IFNAMSIZ). Not derived automatically from guestName since
        guest names may exceed that length.
      '';
    };

    hostAddress = lib.mkOption {
      type = lib.types.str;
      default = "10.100.0.1";
      description = ''
        Host's own address on the point-to-point tap link (routed-network
        pattern, not a bridge — see DECISIONS.md's network section).
      '';
    };

    guestAddress = lib.mkOption {
      type = lib.types.str;
      default = "10.100.0.2";
      description = "Guest's address on the point-to-point tap link.";
    };

    mac = lib.mkOption {
      type = lib.types.str;
      description = "MAC address for the guest's tap interface (locally administered).";
    };

    externalInterface = lib.mkOption {
      type = lib.types.str;
      description = "Host's uplink interface to masquerade guest egress through.";
    };
  };

  config = lib.mkIf cfg.enable {
    microvm.vms.${cfg.guestName} = {
      config = { config, lib, pkgs, ... }: {
        system.stateVersion = "26.05";

        # ── Hypervisor + memory ────────────────────────────────────────────
        # cloud-hypervisor: required for virtiofs shares and --balloon support
        # (firecracker lacks virtiofs, not ballooning as the brief states —
        # see DECISIONS.md). Flat mem + balloon/deflateOnOOM only, no
        # hotplugMem — see DECISIONS.md's memory section for why elastic
        # virtio-mem growth was rejected.
        microvm = {
          hypervisor = "cloud-hypervisor";
          mem = cfg.mem;
          vcpu = cfg.vcpu;
          balloon = cfg.balloon;
          deflateOnOOM = cfg.deflateOnOOM;

          # ── N1: guest owns its store, no host-store share ────────────────
          # microvm.nix's DEFAULT shares the host's /nix/store read-only —
          # exactly the pattern brief constraint #3 forbids. storeOnDisk +
          # writableStoreOverlay (with no `shares` entry for /nix/store)
          # gives the guest its own writable store instead.
          storeOnDisk = true;
          writableStoreOverlay = "/nix/.rw-store";

          volumes = [
            {
              image = "${cfg.storeVolumeDir}/store-overlay.img";
              mountPoint = "/nix/.rw-store";
              fsType = "btrfs";
              size = cfg.storeVolumeSizeMiB;
              autoCreate = true;
            }
            {
              # N3: persistent state — SSH host key (= this guest's sops age
              # identity) lands under here from Phase 3 on, plus agent home
              # and Docker data. Distinct volume from the store overlay so
              # btrbk (Phase 5) only snapshots what's actually worth
              # restoring.
              image = "${cfg.stateVolumeDir}/state.img";
              mountPoint = "/persist";
              fsType = "btrfs";
              size = cfg.stateVolumeSizeMiB;
              autoCreate = true;
            }
          ];

          interfaces = [
            {
              type = "tap";
              id = cfg.interfaceId;
              mac = cfg.mac;
            }
          ];
        };

        # btrfs isn't pulled into a minimal guest's kernel/initrd by default
        # the way it is on the real hosts (whose generated hardware config
        # does that implicitly) — declare it explicitly so the store-overlay
        # and state volumes actually mount.
        boot.supportedFilesystems = [ "btrfs" ];
        boot.initrd.supportedFilesystems = [ "btrfs" ];

        # ── Nix ──────────────────────────────────────────────────────────
        nix.settings = {
          experimental-features = [ "nix-command" "flakes" ];
          substituters = [ "https://cache.nixos.org" ];
        };

        # ── zram ─────────────────────────────────────────────────────────
        # Adapted from modules/nixos/performance.nix, not blind-copied:
        # keep zstd + deflateOnOOM, drop the desktop-tuned swappiness=100
        # (fights balloon reclaim on a memory-resized guest) and the
        # aggressive 90% sizing (this is a fixed 24 GB guest, not a 64 GB
        # box absorbing shader-compile spikes).
        zramSwap = {
          enable = true;
          algorithm = "zstd";
          memoryPercent = 25;
        };

        # ── Guest-side networking ────────────────────────────────────────
        # Routed point-to-point link to the host (matches the host-side
        # config below) — no DHCP, no shared L2 segment. Public resolvers:
        # the guest deliberately cannot reach the fleet's AdGuard/Unbound
        # (LAN-only, walled off by design), so it needs its own.
        networking.useNetworkd = true;
        networking.nameservers = [ "1.1.1.1" "9.9.9.9" ];
        systemd.network.networks."10-uplink" = {
          matchConfig.Type = "ether";
          address = [ "${cfg.guestAddress}/32" ];
          routes = [
            {
              Gateway = cfg.hostAddress;
              GatewayOnLink = true;
            }
          ];
        };
      };
    };

    # ── Host-side networking (Phase 1: connectivity only, NOT containment —
    # Phase 2 adds the N2 denylist on top of this) ──────────────────────────
    networking.networkmanager.unmanaged = [ "interface-name:${cfg.interfaceId}" ];
    systemd.network.enable = true;
    systemd.network.networks."40-${cfg.interfaceId}" = {
      matchConfig.Name = cfg.interfaceId;
      address = [ "${cfg.hostAddress}/32" ];
      routes = [
        { Destination = "${cfg.guestAddress}/32"; }
      ];
      # IPForward was removed upstream in favor of IPv4Forwarding/IPv6Forwarding
      # (systemd.network(5)) — nixpkgs 26.05 rejects the old key.
      networkConfig.IPv4Forwarding = true;
      linkConfig.RequiredForOnline = "no";
    };

    networking.nat = {
      enable = true;
      internalInterfaces = [ cfg.interfaceId ];
      externalInterface = cfg.externalInterface;
    };
    boot.kernel.sysctl."net.ipv4.conf.all.forwarding" = true;
  };
}
