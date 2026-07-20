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

    containmentCheckTailnetAddress = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = ''
        This host's own tailnet IP, used only by the Phase 2 self-check to
        prove containment (a known-listening address makes "blocked" an
        unambiguous signal rather than "maybe nothing's there anyway"). Null
        skips this specific check.
      '';
    };

    containmentCheckLanAddress = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "This host's own LAN IP, same rationale as containmentCheckTailnetAddress.";
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

        # ── Console access (Phase 1 verification only) ──────────────────────
        # No SSH until Phase 3, and a fresh declarative guest has no password
        # set — without this, first boot is a login wall. Root-autologin on
        # the console is a no-op privilege-wise: the only way to *reach* this
        # console at all is already having host-level access to Pegasus
        # (journalctl/microvm tooling), which is a strictly stronger position
        # than guest-root. Kernel console is ttyS0 on x86_64 (cloud-hypervisor
        # `--serial tty`, set by microvm.nix) — tty1's autologin option alone
        # doesn't cover the serial getty, so both are overridden here.
        services.getty.autologinUser = "root";
        systemd.services."serial-getty@ttyS0".serviceConfig.ExecStart = [
          ""
          "${pkgs.util-linux}/sbin/agetty --autologin root --keep-baud 115200,57600,38400,9600 %I $TERM"
        ];

        environment.systemPackages = [ pkgs.curl ];

        # ── Phase 1 gate self-check ────────────────────────────────────────
        # There's no genuine interactive console into this guest yet (the
        # systemd unit wires the guest's console up as journal *output* only
        # — Phase 3's SSH is the real interactive path). Confirmed live: the
        # guest itself boots fine, so the two remaining Phase 1 gate criteria
        # (writable /nix, outbound internet) are checked automatically at
        # boot instead, with the result visible via `journalctl -u
        # microvm@agent-sandbox` on the host — StandardOutput=journal+console
        # routes it through the guest's serial console into that unit's own
        # journal, same path the boot messages already take. Remove once
        # Phase 3 lands and this can just be checked interactively over SSH.
        systemd.services.phase1-verify = {
          description = "Phase 1 gate self-check: writable store + outbound internet";
          after = [ "network-online.target" ];
          wants = [ "network-online.target" ];
          wantedBy = [ "multi-user.target" ];
          path = [ pkgs.curl config.nix.package ];
          serviceConfig = {
            Type = "oneshot";
            StandardOutput = "journal+console";
            StandardError = "journal+console";
          };
          script = ''
            echo "PHASE1-VERIFY: checking outbound internet"
            curl -fsS https://cache.nixos.org/nix-cache-info > /dev/null
            echo "PHASE1-VERIFY: internet OK"
            echo "PHASE1-VERIFY: checking writable store (nix build nixpkgs#hello)"
            nix build --extra-experimental-features 'nix-command flakes' --no-link nixpkgs#hello
            echo "PHASE1-VERIFY: PASS"
          '';
        };

        # ── Phase 2 gate self-check ─────────────────────────────────────────
        # Same rationale as phase1-verify: no interactive console yet. Proves
        # containment by testing reachability to addresses we *know* have
        # something listening (this host's own tailnet/LAN sshd, confirmed
        # live) — a blocked connection there is an unambiguous signal, unlike
        # testing an arbitrary address that might just have nothing running.
        # Uses bash's /dev/tcp for a raw connect test (no nc/curl needed for
        # non-HTTP ports); `timeout` bounds each attempt since a DROP rule
        # causes silent packet loss, not an immediate refusal.
        systemd.services.phase2-verify = lib.mkIf (
          cfg.containmentCheckTailnetAddress != null || cfg.containmentCheckLanAddress != null
        ) {
          description = "Phase 2 gate self-check: containment denylist";
          after = [ "network-online.target" "phase1-verify.service" ];
          wants = [ "network-online.target" ];
          wantedBy = [ "multi-user.target" ];
          path = [ pkgs.curl ];
          serviceConfig = {
            Type = "oneshot";
            StandardOutput = "journal+console";
            StandardError = "journal+console";
          };
          script = ''
            fail=0
            check_blocked() {
              local desc="$1" host="$2" port="$3"
              if timeout 3 bash -c "echo > /dev/tcp/$host/$port" 2>/dev/null; then
                echo "PHASE2-VERIFY: LEAK - $desc ($host:$port) is reachable!"
                fail=1
              else
                echo "PHASE2-VERIFY: blocked as expected - $desc ($host:$port)"
              fi
            }

            echo "PHASE2-VERIFY: checking internet still reachable"
            if curl -fsS -m5 https://cache.nixos.org/nix-cache-info > /dev/null; then
              echo "PHASE2-VERIFY: internet OK"
            else
              echo "PHASE2-VERIFY: FAIL - internet unreachable (denylist too broad?)"
              fail=1
            fi

            ${lib.optionalString (cfg.containmentCheckTailnetAddress != null) ''
              check_blocked "this host's tailnet address" "${cfg.containmentCheckTailnetAddress}" 22
            ''}
            ${lib.optionalString (cfg.containmentCheckLanAddress != null) ''
              check_blocked "this host's LAN address" "${cfg.containmentCheckLanAddress}" 22
            ''}

            if [ "$fail" = "1" ]; then
              echo "PHASE2-VERIFY: FAIL - containment leak detected"
              exit 1
            fi
            echo "PHASE2-VERIFY: PASS"
          '';
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
    # Confirmed live on Pegasus (2026-07-20): enabling systemd-networkd here —
    # even scoped to a single .network file matching only the tap interface —
    # still makes the *daemon* assert broader authority over the system's
    # routing-policy database. It was pruning Tailscale's own ip rules as
    # "foreign" (tailscaled's log: "somebody (likely systemd-networkd) deleted
    # ip rules"), an ongoing fight, not a one-time blip. This tells networkd to
    # leave routes/rules it didn't create alone — NetworkManager and tailscaled
    # both manage routes/rules of their own that networkd would otherwise also
    # consider "foreign" and prune.
    systemd.network.config.networkConfig = {
      ManageForeignRoutingPolicyRules = false;
      ManageForeignRoutes = false;
    };
    # Confirmed live on Pegasus (2026-07-20): systemd-networkd-wait-online
    # times out (120s) at every boot/switch, because the only interface
    # networkd manages here (the guest's tap) doesn't exist until the guest
    # itself starts — a chicken-and-egg boot-time gate for an interface that
    # can never be "online" at the point this runs. NetworkManager already
    # provides real boot-network-readiness via its own wait-online mechanism;
    # nothing needs networkd's copy of that gate to succeed.
    systemd.network.wait-online.enable = false;
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

    # ── N2: containment denylist (Phase 2) ──────────────────────────────────
    # Read directly from nat-iptables.nix rather than assumed: networking.nat's
    # own internalInterfaces mechanism (above) installs a blanket ACCEPT for
    # this interface with no destination filtering of its own — that's exactly
    # why Phase 1's egress was wide-open. These rules take priority by
    # inserting at the very top of FORWARD (-I FORWARD 1) rather than
    # appending, so they're evaluated — and match — before nat's own ACCEPT or
    # anything Docker's chains do.
    #
    # Denylist: the tailnet's CGNAT range (100.64.0.0/10 — not RFC1918; an
    # RFC1918-only rule would leak the whole tailnet, see DECISIONS.md) and the
    # three RFC1918 ranges (covers the LAN, every other fleet host, and
    # Pegasus's own LAN address as natural subsets of 192.168.0.0/16 — no
    # separate per-host rule needed). Pegasus's own addresses (LAN, tailnet, or
    # the tap gateway itself, 10.100.0.1) never actually reach these rules
    # regardless of range: a destination that's local to the receiving host
    # always goes through INPUT, never FORWARD. So Pegasus's own listening
    # services (including Olla, if ever re-enabled) are covered a second way,
    # by the existing INPUT-chain default-deny (nothing opens a port to this
    # interface). IPv6 not handled here — the guest has no IPv6 address
    # configured, so there's nothing to leak over v6 yet; revisit if that
    # changes (Tailscale's own IPv6 range is fd7a:115c:a1e0::/48, confirmed
    # from its own logs on Pegasus, not guessed).
    networking.firewall.extraCommands =
      let
        denylist = [
          "100.64.0.0/10"
          "10.0.0.0/8"
          "172.16.0.0/12"
          "192.168.0.0/16"
        ];
        mkRule = dest: ''
          iptables -w -D FORWARD -i ${cfg.interfaceId} -d ${dest} -j DROP 2>/dev/null || true
          iptables -w -I FORWARD 1 -i ${cfg.interfaceId} -d ${dest} -j DROP
        '';
      in
      lib.concatMapStrings mkRule denylist;

    networking.firewall.extraStopCommands =
      let
        denylist = [
          "100.64.0.0/10"
          "10.0.0.0/8"
          "172.16.0.0/12"
          "192.168.0.0/16"
        ];
        mkRule = dest: ''
          iptables -w -D FORWARD -i ${cfg.interfaceId} -d ${dest} -j DROP 2>/dev/null || true
        '';
      in
      lib.concatMapStrings mkRule denylist;

    # Confirmed live on Pegasus (2026-07-20): microvm@<name>.service runs as
    # User=microvm Group=kvm (fixed by microvm.nix, not configurable), but a
    # freshly created btrfs subvolume defaults to root:root 0755 — same class
    # of bug as @games (see hosts/pegasus/configuration.nix), which needed the
    # identical systemd.tmpfiles.rules fix for the same reason. Without this,
    # microvm-run fails outright trying to touch the volume image files
    # ("Permission denied") and crash-loops.
    systemd.tmpfiles.rules = [
      "d ${cfg.storeVolumeDir} 0750 microvm kvm - -"
      "d ${cfg.stateVolumeDir} 0750 microvm kvm - -"
    ];
  };
}
