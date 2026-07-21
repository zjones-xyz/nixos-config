# ── Isolated agent dev-sandbox (microVM) ────────────────────────────────────
# Shared, parameterized guest module for the isolated coding-agent sandbox.
# See docs/microvm-sandbox/DECISIONS.md for the full design rationale (N1–N4,
# the memory model, store/volume layout, network approach). Phases 1-2 have
# landed and are verified live on Pegasus (guest boots, writable store,
# outbound internet, and the network containment denylist below — see
# DECISIONS.md for the full verification history, including bugs found and
# fixed along the way). Phase 3 (agent user, Docker, SSH, persistent state)
# in progress — see that section below.
#
# sops-nix/impermanence are passed in as plain values (via specialArgs on the
# *host's* nixosSystem call, e.g. hosts/pegasus's specialArgs in flake.nix) —
# not imported the normal top-level way — because they need to be imported
# into the *guest's* own nested module evaluation below, a separate NixOS
# system from the host itself.
{ config, lib, pkgs, sops-nix, impermanence, ... }:

let
  cfg = config.homelab.agentSandbox;
  # N2 containment denylist — shared between extraCommands/extraStopCommands
  # so the two can't drift out of sync with each other.
  n2Denylist = [
    "100.64.0.0/10" # tailnet CGNAT
    "10.0.0.0/8" # RFC1918
    "172.16.0.0/12" # RFC1918
    "192.168.0.0/16" # RFC1918
  ];

  # Shared between networking.firewall.extraCommands/extraStopCommands AND
  # the containment-reassert service below (see its comment for why a second
  # application point is needed) — one script, applied from two places,
  # rather than two copies that can drift.
  mkForwardDelete = dest: ''
    iptables -w -D FORWARD -i ${cfg.interfaceId} -d ${dest} -j DROP 2>/dev/null || true
  '';
  mkForwardInsert = dest: mkForwardDelete dest + ''
    iptables -w -I FORWARD 1 -i ${cfg.interfaceId} -d ${dest} -j DROP
  '';
  inputDelete = ''
    iptables -w -D INPUT -i ${cfg.interfaceId} -j DROP 2>/dev/null || true
  '';
  inputInsert = inputDelete + ''
    iptables -w -I INPUT 1 -i ${cfg.interfaceId} -j DROP
  '';

  containmentApplyScript = lib.concatMapStrings mkForwardInsert n2Denylist + inputInsert;
  containmentRemoveScript = lib.concatMapStrings mkForwardDelete n2Denylist + inputDelete;
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

    operatorSshKeys = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = ''
        Public keys authorized for the guest's `agent` user (Phase 3). Passed
        explicitly per-instance rather than referencing a fleet user's keys
        from inside this shared module, since which operator/key is
        appropriate may differ per guest.
      '';
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

        environment.systemPackages = [ pkgs.curl pkgs.claude-code pkgs.codex ];

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
        # Same rationale as phase1-verify: no interactive console yet.
        #
        # CONFIRMED LIVE ON PEGASUS (2026-07-21) that testing this *host's
        # own* addresses does NOT exercise these rules: a packet whose
        # destination is local to the receiving host never enters the
        # FORWARD chain at all — the kernel routes it straight to INPUT
        # instead, regardless of any FORWARD-chain rule. The first version of
        # this check tested Pegasus's own tailnet/LAN addresses and got a
        # clean "blocked as expected" — but from the pre-existing INPUT-chain
        # default-deny, not from these rules; `iptables -L FORWARD -n -v`
        # showed all four DROP rules at 0 packets/0 bytes despite the test
        # "passing". Fixed by testing synthetic representative addresses
        # *within* each denylist range instead — genuinely non-local, so
        # forwarding actually has to happen and these rules actually fire.
        #
        # Uses bash's /dev/tcp for a raw connect test (no nc/curl needed for
        # non-HTTP ports); `timeout` bounds each attempt since a DROP rule
        # causes silent packet loss, not an immediate refusal. A timeout here
        # is suggestive but not fully definitive on its own (a synthetic
        # address might also just have nothing listening, coincidentally) —
        # the authoritative proof is still `iptables -L FORWARD -n -v` on the
        # host showing nonzero counters on the four DROP rules after this runs.
        #
        # CONFIRMED LIVE ON PEGASUS (2026-07-21), second bug: even after
        # switching to synthetic non-local targets above, every check still
        # "passed" in ~2-8ms each -- nowhere near the 3s timeout, and the
        # FORWARD counters stayed at 0/0. `path` here never included
        # `pkgs.bash`, so the nested `timeout 3 bash -c "..."` failed
        # instantly with "bash: No such file or directory" -- every prior
        # "timed out (expected)" line was actually a shell-not-found error,
        # never a real connection attempt. A positive control (identical
        # /dev/tcp call against a known-open port) hit the same error,
        # confirming the mechanism itself, not the network, was broken.
        # `pkgs.bash` in `path` below is the fix.
        systemd.services.phase2-verify = {
          description = "Phase 2 gate self-check: containment denylist";
          after = [ "network-online.target" "phase1-verify.service" ];
          wants = [ "network-online.target" ];
          wantedBy = [ "multi-user.target" ];
          path = [ pkgs.curl pkgs.bash ];
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
                echo "PHASE2-VERIFY: timed out (expected) - $desc ($host:$port) -- confirm with iptables counters, not this alone"
              fi
            }

            echo "PHASE2-VERIFY: checking internet still reachable"
            if curl -fsS -m5 https://cache.nixos.org/nix-cache-info > /dev/null; then
              echo "PHASE2-VERIFY: internet OK"
            else
              echo "PHASE2-VERIFY: FAIL - internet unreachable (denylist too broad?)"
              fail=1
            fi

            # Synthetic, non-local addresses within each denylist range —
            # not Pegasus's own addresses (see comment above for why this
            # doesn't exercise the FORWARD-chain rules).
            check_blocked "tailnet CGNAT range" "100.64.0.1" 22
            check_blocked "RFC1918 10.0.0.0/8" "10.0.0.1" 22
            check_blocked "RFC1918 172.16.0.0/12" "172.16.0.1" 22
            check_blocked "RFC1918 192.168.0.0/16" "192.168.1.1" 22

            # Regression test for a real containment bypass found by
            # independent review (2026-07-21) and confirmed live: this host's
            # own gateway address IS local-to-host traffic, so it bypasses
            # FORWARD and none of the four checks above exercise it at all.
            # sshd was reachable here via the fleet-wide openssh.openFirewall
            # default before the host-side INPUT-chain deny was added.
            check_blocked "this host's own gateway (INPUT-chain path, not FORWARD)" "${cfg.hostAddress}" 22

            if [ "$fail" = "1" ]; then
              echo "PHASE2-VERIFY: FAIL - containment leak detected"
              exit 1
            fi
            echo "PHASE2-VERIFY: PASS (timeouts alone aren't fully definitive -- confirm with iptables -L FORWARD -n -v on the host that the four DROP rules show nonzero counters)"
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

        # ── Phase 3: agent user, Docker, SSH, persistent state ──────────────
        # sops-nix/impermanence imported here (not at the top level of this
        # file) — they need to apply to the *guest's* own module evaluation,
        # not the host's. Both values reach this scope via this file's own
        # { config, lib, pkgs, sops-nix, impermanence, ... }: signature,
        # captured by ordinary Nix lexical closure (this whole block is still
        # just a nested function value, not a separate file) — no need for
        # microvm.nix's extraModules/specialArgs plumbing.
        imports = [ sops-nix.nixosModules.sops impermanence.nixosModules.impermanence ];

        # impermanence asserts every path it persists sits on a filesystem
        # marked neededForBoot. CONFIRMED via direct source check
        # (nixos-modules/microvm/mounts.nix) that microvm.nix's own
        # volumes-to-fileSystems translation only sets this automatically for
        # the *writableStoreOverlay* mountpoint (/nix/.rw-store) — a plain
        # secondary volume like /persist does not get it for free, despite
        # earlier (wrong) assumption otherwise. Set explicitly.
        fileSystems."/persist".neededForBoot = true;

        services.openssh.enable = true;

        users.users.agent = {
          isNormalUser = true;
          # Pinned rather than left to NixOS's dynamic uid allocation:
          # `nix flake check` surfaced impermanence's own warning that
          # dynamically-allocated uids/gids live in /var/lib/nixos, which
          # isn't itself persisted here — on this ephemeral-root guest,
          # `agent`'s uid could silently drift across a restart, orphaning
          # everything already persisted under uid 1000 on /persist. Pinning
          # it removes the dependency on that allocation state entirely,
          # cheaper than also persisting /var/lib/nixos wholesale for the one
          # user this actually matters for. The primary group ("users",
          # gid 100) is NixOS's own static, non-dynamically-allocated group —
          # not part of this problem, confirmed by its absence from the same
          # warning's flagged-groups list.
          uid = 1000;
          # docker: grants access to the rootful daemon socket — root-
          # equivalent inside the guest, but the guest itself is the actual
          # security boundary here (the whole point of this design), so
          # that's an acceptable trade in a way it wouldn't be for a fleet
          # host's own user.
          extraGroups = [ "docker" ];
          openssh.authorizedKeys.keys = cfg.operatorSshKeys;
          shell = pkgs.bash;
        };

        virtualisation.docker = {
          enable = true;
          # Nested is fine — Docker uses namespaces/cgroups, not its own
          # hypervisor, so there's no nested-KVM concern running it inside a
          # cloud-hypervisor guest. Data root on /persist (N3) — see below.
          daemon.settings.data-root = "/persist/var/lib/docker";
        };

        # N3: SSH host key (= sops age identity below), agent's home, and
        # Docker's data root all need to survive a guest restart — this
        # guest's root is ephemeral by default (microvm.nix), so anything not
        # explicitly persisted here evaporates on every restart. See
        # flake.nix's impermanence input comment for why this uses
        # impermanence rather than hand-rolled bind mounts.
        #
        # SSH host key: left at its normal default path
        # (/etc/ssh/ssh_host_ed25519_key) rather than redirected via
        # services.openssh.hostKeys to a custom /persist/... path — sshd's own
        # key-generation unit (sshd-keygen) is ordered at multi-user.target,
        # after impermanence's bind-mount (local-fs.target), so the persisted
        # key is already in place by the time sshd would otherwise generate a
        # fresh one. Public key persisted via a symlink instead of a second
        # bind mount, since it's cheaply re-derivable — matches impermanence's
        # own upstream example for this exact file pair.
        #
        # /var/lib/docker and /home/agent: explicit per-entry ownership
        # (not the users.<name>.directories convenience wrapper, whose paths
        # are relative to that user's home — for persisting a directory
        # wholesale rather than specific subpaths within an otherwise-
        # ephemeral home, a plain top-level directories entry is more direct).
        environment.persistence."/persist" = {
          hideMounts = true;
          files = [
            "/etc/ssh/ssh_host_ed25519_key"
            { file = "/etc/ssh/ssh_host_ed25519_key.pub"; method = "symlink"; }
          ];
          directories = [
            { directory = "/var/lib/docker"; user = "root"; group = "root"; mode = "0711"; }
            { directory = "/home/agent"; user = "agent"; group = "users"; mode = "0755"; }
          ];
        };

        # ── Guest's own sops age identity (N3) — distinct from every fleet
        # host's, per docs/microvm-sandbox/DECISIONS.md's Secrets section.
        # Gated on the secrets file existing yet, same pattern as every real
        # host in this repo (e.g. hosts/pegasus/configuration.nix's hasSops):
        # the file can't exist until the guest's real age pubkey is known,
        # which needs a first boot — see docs/microvm-sandbox/SECRETS-TODO.md
        # for the exact ceremony. `../../secrets + "/${cfg.guestName}.yaml"`
        # rather than `../../secrets/${cfg.guestName}.yaml` — bare Nix path
        # literals don't support string interpolation, only path+string
        # concatenation does.
        sops = lib.mkIf (builtins.pathExists (../../secrets + "/${cfg.guestName}.yaml")) {
          defaultSopsFile = ../../secrets + "/${cfg.guestName}.yaml";
          age.sshKeyPaths = [ "/etc/ssh/ssh_host_ed25519_key" ];
          secrets."CLAUDE_CODE_OAUTH_TOKEN" = {
            owner = "agent";
            group = "users";
            mode = "0400";
          };
        };

        # N4: the token needs to reach an *interactive* shell (agents run
        # over SSH), not a systemd service's EnvironmentFile= (never reached)
        # or environment.variables (world-readable via /proc/*/environ).
        # Safe to leave unconditional on whether the secret above is actually
        # wired up yet — the `-r` check just fails gracefully (no file exists
        # yet) until it is.
        environment.interactiveShellInit = ''
          if [ -r /run/secrets/CLAUDE_CODE_OAUTH_TOKEN ]; then
            export CLAUDE_CODE_OAUTH_TOKEN="$(cat /run/secrets/CLAUDE_CODE_OAUTH_TOKEN)"
          fi
        '';
      };
    };

    assertions = [
      {
        assertion = builtins.stringLength cfg.interfaceId <= 15;
        message = ''
          homelab.agentSandbox.interfaceId ("${cfg.interfaceId}") is longer than 15
          characters — Linux's IFNAMSIZ limit. Without this assertion, evaluation
          would succeed and the failure would only surface later as an opaque
          tap/ip-link error at activation or boot time.
        '';
      }
    ];

    # ── Host-side networking (containment denylist below) ───────────────────
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
    # separate per-host rule needed).
    #
    # CORRECTED 2026-07-21 (independent review + live verification): traffic
    # destined for Pegasus's own addresses (LAN, tailnet, or the tap gateway
    # itself) never reaches these FORWARD rules — it goes through INPUT
    # instead — and an earlier version of this comment assumed that meant it
    # was automatically blocked. **That was wrong and was a real, confirmed
    # containment bypass**: `services.openssh.openFirewall` defaults to true
    # (never overridden anywhere in this repo) and `networking.firewall.
    # interfaces` is empty, so port 22 (and gaming.nix's Steam Remote Play
    # ports) are allowed on *every* interface, including this one — the guest
    # could `ssh 10.100.0.1` and reach Pegasus's real sshd directly. Fixed
    # below with an explicit INPUT-chain deny for this interface: the guest
    # has no legitimate reason to reach any service on Pegasus itself (it
    # only needs the host as a routing hop, a FORWARD-chain matter, not
    # INPUT), so this is a blanket deny rather than an itemized port list —
    # an itemized list is exactly what silently rotted here once already, the
    # moment some unrelated module opened a new global port.
    #
    # IPv6: the guest has no IPv6 address configured and Pegasus never enables
    # IPv6 forwarding (confirmed: no ipv6-forwarding sysctl set for pegasus;
    # the fleet's tailscale.nix module that sets it is only imported by
    # hopper). That's an invariant, not an enforced property, until the
    # explicit sysctl override below — added so this containment can't
    # silently break if IPv6 forwarding is ever turned on for an unrelated
    # reason. Tailscale's own IPv6 range is fd7a:115c:a1e0::/48 (confirmed
    # from its own logs on Pegasus, not guessed) if this ever needs revisiting
    # for real.
    boot.kernel.sysctl."net.ipv6.conf.all.forwarding" = lib.mkForce false;

    networking.firewall.extraCommands = containmentApplyScript;
    networking.firewall.extraStopCommands = containmentRemoveScript;

    # CONFIRMED LIVE ON PEGASUS (2026-07-21), genuine cold-reboot test: on a
    # cold boot, firewall.service (which carries the rules above via
    # extraCommands) runs early -- before docker.service/tailscaled.service
    # exist -- so when those services later install their OWN top-of-chain
    # hooks (DOCKER-USER/DOCKER-FORWARD, ts-forward/ts-input), those land
    # ABOVE these DROP rules instead of below:
    #   `iptables -L FORWARD -n -v` showed ts-forward, DOCKER-USER, and
    #   DOCKER-FORWARD sitting ahead of all four DROP rules after a cold
    #   reboot -- the opposite of the order confirmed during Phase 2's
    #   switch-based verification.
    # On a `nixos-rebuild switch`, by contrast, firewall.service only
    # *restarts* (because the config changed) with docker/tailscaled already
    # running, so the reinsertion happens last and lands on top -- which is
    # exactly why the switch-based Phase 2 verification never caught this:
    # it never tested a genuine cold start, only a warm one.
    # Containment still held in the cold-boot test (iptables counters stayed
    # nonzero, self-check passed) because Docker's and Tailscale's chains
    # apparently RETURN rather than ACCEPT traffic on this interface -- but
    # that's incidental, not structural: it depends on those chains never
    # gaining a rule that happens to match this interface or its
    # destinations. This service re-asserts the identical rules, ordered
    # explicitly after docker.service/tailscaled.service/firewall.service,
    # so they land on top deterministically regardless of cold-boot vs.
    # switch ordering. `after` (not `wants`/`requires`) is deliberate: it
    # only orders relative to those units if they exist and are going to
    # run anyway, so this is harmless on a host without Docker/Tailscale.
    # Known residual gap, not solved here: if docker.service or
    # tailscaled.service itself gets restarted by a *later* unrelated switch
    # (after this unit already ran earlier in the same switch), the race
    # could reopen. Out of scope for this fix -- flagged in DECISIONS.md.
    systemd.services."agent-sandbox-containment-reassert" = {
      description = "Re-assert homelab.agentSandbox containment rules after Docker/Tailscale";
      after = [ "docker.service" "tailscaled.service" "firewall.service" ];
      wantedBy = [ "multi-user.target" ];
      path = [ pkgs.iptables ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = containmentApplyScript;
    };

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
