{ config, pkgs, lib, ... }:

# ─────────────────────────────────────────────────────────────────────────────
# galactica — Tower, bare-metal NixOS (Supermicro X9SCM-F, ex-Unraid).
# ─────────────────────────────────────────────────────────────────────────────
# Root: LUKS + btrfs on the NVMe (disko.nix), like the rest of the fleet.
# ZFS lives only in `tank`, the RAIDZ1 media array — DECISIONS.md §7,
# MANUAL-STEPS.md §9.
# ⚠ /boot is on the WD Blue's ESP, NOT the NVMe — the firmware can't UEFI-boot
# the NVMe or anything behind the HBA; hardware-configuration.nix's header has
# the story and is why canTouchEfiVariables is false below.

{
  imports = [
    ./hardware-configuration.nix
    ../../modules/nixos/common.nix
    ../../modules/nixos/btrfs-snapshots.nix
    ../../modules/nixos/serial-console.nix
    ../../modules/nixos/luks-remote-unlock.nix
    ../../modules/nixos/beszel-agent.nix
    ../../modules/nixos/arcane-agent.nix
    ../../modules/nixos/scrutiny-collector.nix
    ../../modules/nixos/dns.nix
    ../../modules/nixos/adguardhome-sync.nix
    ../../modules/nixos/traefik-galactica.nix
    ../../modules/nixos/newt.nix
    ./borgmatic.nix
    ./homepages.nix
    ./nixflix.nix
    ./unpackerr.nix
    ./bazarr.nix
  ];

  networking.hostName = "galactica";
  networking.networkmanager.enable = true;

  # BIOS SOL covers POST and the bootloader only — the kernel needs its own
  # console= or SOL goes dark when it takes over (live-iso.nix, PLATFORM.md §2).
  homelab.serialConsole.device = "ttyS1,115200n8";

  # `tower.internal` keeps resolving to this host via an AdGuard rewrite —
  # DECISIONS.md §2. That rewrite now lives below (galactica is the AdGuard
  # instance itself, migrated off the router's UI-only config), not on
  # hopper's dead dns.nix import. Static reservation on the router is still
  # the intended mechanism for this host's own IP, not a static IP here.

  # ── AdGuard admin login — bcrypt hash, not a sops secret ────────────────────
  # Can't reference sops here: this file renders into AdGuardHome.yaml at
  # build time, before secrets decrypt on the target host (MANUAL-STEPS.md
  # §12). A bcrypt hash is the credential-safe form to commit directly.
  services.adguardhome.settings.users = [
    { name = "admin"; password = "$2y$10$8TU89p4pf3Up.YCaKacwJe1kAkP2sQMu8xsXaL0TjYNVxD8hs4ybm"; }
  ];

  # Query log retention — 60 days on this box specifically (not a fleet
  # default in dns.nix; hopper/hamilton's eventual RAM-only logging is a
  # different tradeoff). `interval` is a duration string, 1h–8760h.
  services.adguardhome.settings.querylog.interval = "1440h";

  # Stats retention (aggregated top-domains/clients, distinct from the raw
  # query log above) — 90 days, same per-host reasoning. Same duration-string
  # format/bounds as querylog.
  services.adguardhome.settings.statistics.interval = "2160h";

  # AdGuard's web UI defaults to 127.0.0.1:3000 only (confirmed live —
  # unreachable from the LAN until this). Routed via Traefik under
  # galactica.internal/galactica.zjones.dev — not arrExtraUpstreams, since
  # that publishes under arr.*, and AdGuard isn't part of the media stack.
  # *.galactica.internal/*.galactica.zjones.dev already resolve to galactica
  # (rewrites below), so no new DNS entry needed. ⚠ Unlike an arrExtraUpstreams
  # entry, the -dev router below has no matching wildcard cert to dedup
  # against (traefik-galactica.nix's `domains` only covers arr.zjones.dev),
  # so this requests its own single-name LE cert for
  # adguard.galactica.zjones.dev — a one-time, deliberate cost, not a
  # repeatable per-router one.
  services.traefik.dynamicConfigOptions.http = {
    routers = {
      adguard = {
        rule = "Host(`adguard.galactica.internal`)";
        entrypoints = [ "websecure" ];
        tls = { };
        service = "adguard-svc";
      };
      "adguard-dev" = {
        rule = "Host(`adguard.galactica.zjones.dev`)";
        entrypoints = [ "websecure" ];
        tls.certResolver = "letsencrypt";
        service = "adguard-svc";
      };
    };
    services.adguard-svc.loadBalancer.servers = [ { url = "http://127.0.0.1:3000"; } ];
  };

  # ── DNS rewrites — migrated off the router's AdGuard instance ──────────────
  # These lived only in the router's mutable UI state (hand-clicked, not
  # tracked anywhere) until now. Grouped by physical box, not alphabetically,
  # since several boxes answer to more than one name: galactica is also
  # `tower`/`arr` (legacy identities it absorbed, DECISIONS.md §2), and
  # memory-alpha is also `nixie`. One duplicate row (`arr.zjones.dev`, twice
  # in the router's list) was dropped here.
  #
  # `.xyz` is the owner's convention for externally-routable names — terminated
  # by Pangolin (tunneling to a Newt client), not Traefik, so no local router
  # or cert is expected for these. jellyfin/guest get the split-horizon
  # treatment (LAN clients hit the box directly instead of round-tripping
  # through the tunnel) since they're meant to work both on- and off-network
  # without Tailscale. homeassistant deliberately does NOT — stays
  # Tailscale/LAN-only, no `.xyz` name at all. The *arr stack's `.xyz` route
  # was dropped entirely (owner's call: not needed). `home` (the admin
  # dashboard) also gets no `.xyz` name — it's LAN/tailnet-only by design.
  # ⚠ `enabled = true` is mapped over every entry below, not written per-line
  # — AdGuard 0.107.78 added a per-rewrite enable toggle that isn't in most
  # docs yet, and an omitted bool renders as Go's zero-value (`false`), so
  # every rewrite loaded silently disabled until this was caught live
  # (2026-09-06: every dig came back NXDOMAIN via real recursive resolution,
  # not a rewrite hit).
  services.adguardhome.settings.filtering.rewrites = map (r: r // { enabled = true; }) [
    # router (GL.iNet)
    { domain = "router.internal"; answer = "192.168.8.1"; }

    # hopper
    { domain = "hopper.internal"; answer = "192.168.8.10"; }

    # pegasus
    { domain = "pegasus.internal"; answer = "192.168.8.72"; }

    # memory-alpha-2
    { domain = "memory-alpha-2.internal"; answer = "192.168.8.98"; }
    { domain = "*.memory-alpha-2.internal"; answer = "192.168.8.98"; }

    # memory-alpha (also answers to the legacy name "nixie")
    { domain = "memory-alpha.internal"; answer = "192.168.8.99"; }
    { domain = "*.memory-alpha.internal"; answer = "192.168.8.99"; }
    { domain = "*.memory-alpha.zjones.dev"; answer = "192.168.8.99"; }
    { domain = "*.monitor.zjones.dev"; answer = "192.168.8.99"; }
    { domain = "nixie.internal"; answer = "192.168.8.99"; }
    { domain = "*.nixie.internal"; answer = "192.168.8.99"; }
    # jellyfin.zjones.dev: flat name, not *.memory-alpha.zjones.dev — Traefik
    # (modules/nixos/traefik.nix, on memory-alpha) already routes it with its
    # own single-name LE cert; this rewrite was the only missing piece.
    { domain = "jellyfin.zjones.dev"; answer = "192.168.8.99"; }
    # jellyfin.zjones.xyz: split-horizon shortcut for the Pangolin-tunneled
    # public name — Newt runs on memory-alpha (jellyfin.nix), so this is a
    # LAN clients-only bypass, not a second route.
    { domain = "jellyfin.zjones.xyz"; answer = "192.168.8.99"; }

    # homeassistant
    { domain = "homeassistant.internal"; answer = "192.168.8.142"; }

    # towerbmc (Tower's physical BMC/IPMI — separate NIC from galactica itself)
    { domain = "towerbmc.internal"; answer = "192.168.8.191"; }

    # galactica (also answers to the legacy names "tower" and "arr")
    { domain = "galactica.internal"; answer = "192.168.8.190"; }
    { domain = "*.galactica.internal"; answer = "192.168.8.190"; }
    { domain = "*.galactica.zjones.dev"; answer = "192.168.8.190"; }
    { domain = "tower.internal"; answer = "192.168.8.190"; }
    { domain = "*.tower.internal"; answer = "192.168.8.190"; }
    { domain = "tower.zjones.dev"; answer = "192.168.8.190"; }
    { domain = "*.tower.zjones.dev"; answer = "192.168.8.190"; }
    { domain = "arr.internal"; answer = "192.168.8.190"; }
    { domain = "*.arr.internal"; answer = "192.168.8.190"; }
    { domain = "arr.zjones.dev"; answer = "192.168.8.190"; }
    { domain = "*.arr.zjones.dev"; answer = "192.168.8.190"; }
    # The two dashboards (hosts/galactica/homepages.nix) — flat names, own
    # Traefik router pair each, not under arr.* or galactica.*.
    { domain = "home.internal"; answer = "192.168.8.190"; }
    { domain = "home.zjones.dev"; answer = "192.168.8.190"; }
    { domain = "guest.internal"; answer = "192.168.8.190"; }
    { domain = "guest.zjones.dev"; answer = "192.168.8.190"; }
    { domain = "guest.zjones.xyz"; answer = "192.168.8.190"; }
  ];

  # ── AdGuardHome-Sync — galactica (origin) → router (first replica) ─────────
  # Owner confirmed galactica's rewrites match the router's live list;
  # enabled 2026-09-06. runOnStart is hardcoded true in the module, so the
  # first sync fires immediately once this deploys.
  # hopper/hamilton join `replicas` once they're rebuilt as the ephemeral
  # resolvers discussed — not yet, since neither exists today.
  services.adguardhomeSync = {
    enable = true;
    originPasswordFile = config.sops.secrets."adguardhome-sync/originPassword".path;
    replicas = [
      {
        # GL.iNet's bundled AdGuard sits behind the router's own reverse
        # proxy — adguardhome-sync's wiki (Integration‐GL.iNet) is explicit:
        # no port here, unlike a normal AdGuard instance. :3000 answered our
        # earlier manual curl tests fine but isn't the right path for this
        # tool. GL.iNet also ships with no default AdGuard user at all — one
        # must be created by hand via SSH (users: block in the router's own
        # /etc/AdGuardHome/config.yaml, same bcrypt-hash mechanism as
        # galactica's own admin above).
        url = "http://192.168.8.1";
        # CONFIRM_ME_LIVE — the username already configured on the router
        # (used successfully in the very first manual curl login test, before
        # this file existed). Not "admin", not empty — both failed live.
        username = "CONFIRM_ME_LIVE";
        passwordFile = config.sops.secrets."adguardhome-sync/routerPassword".path;
      }
    ];
  };

  # Mandatory for ZFS. Derived from the hostname (`sha256sum
  # <<<"galactica.internal" | head -c8`) so it is reproducible; no other meaning.
  networking.hostId = "f9e250c9";

  boot.loader.systemd-boot.enable = true;
  # ⚠ FALSE, deliberately: this BIOS boots ONLY the removable-media fallback
  # path, the working NVRAM entry is hand-owned, and letting NixOS register
  # its own just adds an unbootable entry the firmware prunes at POST.
  # hardware-configuration.nix's /boot header is canonical.
  boot.loader.efi.canTouchEfiVariables = false;

  # ── ZFS (the RAIDZ1 array, built separately — see the header note) ─────────
  boot.supportedFilesystems = [ "zfs" ];
  boot.zfs.forceImportRoot = false; # root is btrfs, not ZFS — nothing to force here
  services.zfs.autoScrub = {
    enable = true;
    interval = "monthly";
  };
  # For the special vdev's deliberate overprovisioning to pay off, discards
  # must also pass the LUKS layer (`discard` in crypttab below) or dm-crypt
  # silently drops them.
  services.zfs.trim = {
    enable = true;
    interval = "weekly";
  };

  # ── tank import ordering (LUKS-under-ZFS) ──────────────────────────────────
  # (a) scan /dev/mapper, not the by-id default, or import finds nothing;
  # (b) order after each mapper unit BY NAME — `nofail` crypttab entries are
  #     not pulled in by cryptsetup.target, so that target alone can be reached
  #     with zero mappers open and only nixpkgs' 60s import-retry loop would
  #     save a slow cold boot;
  # (c) extraPools, because tank's datasets use native ZFS mountpoints, so
  #     nothing else triggers the import at boot.
  boot.zfs.devNodes = "/dev/mapper";
  boot.zfs.extraPools = [ "tank" ];
  systemd.services."zfs-import-tank" = {
    # Names must match the crypttab above; `-` escapes to \x2d in unit names.
    after = [ "cryptsetup.target" ] ++ map
      (n: "systemd-cryptsetup@${lib.replaceString "-" "\\x2d" n}.service") [
        "array-HJDH"
        "array-NS3Y"
        "array-X4WE"
        "array-T97E"
        "special-3255"
        "special-768C"
        "special-8162"
      ];
  };

  # Pressure release valve, not a memory tier (swap partition: disko.nix).
  boot.kernel.sysctl."vm.swappiness" = 10;

  # ── crypttab: stage-2 LUKS opens (midden's log partition + tank) ───────────
  # Data disks, not root, so no initrd unlock — DECISIONS.md §7. Keyfiles come
  # from sops; MANUAL-STEPS.md §4/§9 carry the provisioning record.
  # ⚠ `discard` here is load-bearing: disko's allowDiscards only emits initrd
  # options, which never apply to these stage-2 devices — this crypttab flag
  # is the one place TRIM actually passes the dm-crypt layer.
  environment.etc."crypttab" = {
    text = ''
      cryptlogs UUID=b44e545c-b4b3-4037-a263-d5a522933b37 ${config.sops.secrets."luks/middenKeyFile".path} luks,discard,nofail

      # ── ZFS array `tank` — LUKS-under-ZFS members (MANUAL-STEPS.md §9) ────────
      # Opened in stage-2 (not initrd — data disks, not root, DECISIONS.md §7),
      # all keyed by the one sops arrayKeyFile. Mapper names match what `zpool
      # create` imported and what boot.zfs.devNodes = "/dev/mapper" re-imports
      # by. `nofail` on every line so a missing disk or keyfile degrades the
      # boot rather than blocking it — and so tank's import (ordered after
      # cryptsetup.target below) can proceed with whatever opened. `discard`
      # only on the three SSD special-vdev members; the four spinners get none
      # (TRIM is meaningless on an HDD, and they were opened without it).
      array-HJDH   UUID=0e3ffb41-6b97-4a7d-9581-27c6987ef21c ${config.sops.secrets."luks/arrayKeyFile".path} luks,nofail
      array-NS3Y   UUID=d55d13e2-91b1-4bba-96da-2f25facee673 ${config.sops.secrets."luks/arrayKeyFile".path} luks,nofail
      array-X4WE   UUID=78811230-8648-4b32-afcc-c93fbb99e927 ${config.sops.secrets."luks/arrayKeyFile".path} luks,nofail
      array-T97E   UUID=dbf28412-07e7-4b61-8afa-33c38bd6d1f6 ${config.sops.secrets."luks/arrayKeyFile".path} luks,nofail
      special-3255 UUID=016d6496-2bc1-456d-bdcc-21ca45436d5e ${config.sops.secrets."luks/arrayKeyFile".path} luks,discard,nofail
      special-768C UUID=f0a8f677-290b-4607-9422-d3cbd43b7666 ${config.sops.secrets."luks/arrayKeyFile".path} luks,discard,nofail
      special-8162 UUID=2fccd949-3fad-4a91-a218-c55aab11c553 ${config.sops.secrets."luks/arrayKeyFile".path} luks,discard,nofail
    '';
  };

  # Build scratch off the NVMe root. ⚠ `build-dir`, NOT `sandbox-build-dir` —
  # the latter is the path *inside* the sandbox, not where scratch lives.
  nix.settings.build-dir = "/var/cache/nix-build";

  # Container logs otherwise stay in /var/lib/docker on the NVMe, bypassing
  # the dedicated logs disk; journald routes them with everything else.
  virtualisation.docker.daemon.settings.log-driver = "journald";

  # The fleet's 500M cap would waste the 48G logs partition. `mkAfter`, not
  # `mkForce`: journald.conf is last-key-wins, so this extends the fleet
  # default rather than replacing it — dropping this line falls back sanely.
  services.journald.extraConfig = lib.mkAfter ''
    SystemMaxUse=32G
    MaxRetentionSec=180day
  '';

  # ── LUKS SSH unlock (root only — DECISIONS.md §7) ──────────────────────────
  # Shared flow: modules/nixos/luks-remote-unlock.nix. The host piece is the
  # initrd NIC driver (e1000e — the onboard Intel 82574L, PLATFORM.md).
  boot.initrd.availableKernelModules = lib.mkAfter [ "e1000e" ];

  # ── Monitoring agents — report galactica to memory-alpha ────────────────────
  # Both hubs are on always-on memory-alpha, not backburnered hopper (whose
  # modules/nixos/{beszel,ntfy}.nix are hopper-shaped and unused here).
  # ⚠ Registration and secrets are owner steps: MANUAL-STEPS.md §7.
  services.beszelAgent = {
    enable = true;
    # The hub pulls from this agent over the LAN, so the port must be open.
    openFirewall = true;
    keyFile = config.sops.secrets."beszel/hubKey".path;
    tokenFile = config.sops.secrets."beszel/agentToken".path;
    # hubUrl / port / image default to the fleet's values — see beszel-agent.nix.
  };

  # Edge mode: dials out, no inbound port; the .zjones.dev name carries a
  # valid LE cert so agent TLS just works.
  services.arcaneAgent = {
    # managerUrl defaults to the fleet manager — see arcane-agent.nix.
    enable = true;
    tokenFile = config.sops.secrets."arcane/agentToken".path;
  };

  # SMART trend history → the Scrutiny hub on memory-alpha; smartd (below)
  # stays the local alerter.
  services.scrutinyCollector.enable = true;

  # ── Remote access for the dashboards (homepages.nix) ───────────────────────
  # Tailscale carries the admin homepage (and SSH) over the tailnet. No sops
  # authKeyFile on purpose: the key would only cover the one-time join, and
  # this host is already SSH-able — the owner runs `tailscale up` once
  # (MANUAL-STEPS.md §13) and state persists in /var/lib/tailscale.
  services.tailscale.enable = true;

  # The guest homepage's door: Newt tunnels guest.zjones.xyz in from the
  # Pangolin VPS. ⚠ Commented until the Pangolin Site for galactica exists —
  # the id below is issued at creation (same reasoning as the NUT block: a
  # made-up id fails at service start, not eval, and would be easy to miss).
  # §13 has the steps, including the `newt/clientSecret` sops entry this
  # enables.
  # homelab.newt = {
  #   enable = true;
  #   id = "CONFIRM_ME_FROM_PANGOLIN"; # Pangolin → Sites → create "galactica"
  # };

  # ── NUT — pending: galactica is to be the UPS server ───────────────────────
  # Deliberately NOT modules/nixos/nut.nix (that file is hopper's own server
  # config, not a template). The ready-to-paste config, the naming constraints
  # nut-client.nix imposes, and the nut-scanner step are MANUAL-STEPS.md §6.

  # ── sops-nix ────────────────────────────────────────────────────────────────
  # x86_64, builds its own closure (unlike hopper/hamilton, which need
  # memory-alpha as aarch64 build+validation host) — so per DECISIONS.md §4
  # the recipients are *admin + *galactica, both in .sops.yaml since first boot.
  sops = {
    defaultSopsFile = ../../secrets/galactica.yaml;
    age.sshKeyPaths = [ "/etc/ssh/ssh_host_ed25519_key" ];
    secrets = {
      "luks/middenKeyFile" = { };
      # owner = "z": each agent's compose invocation reads these.
      "beszel/hubKey".owner = "z";
      "beszel/agentToken".owner = "z";
      "arcane/agentToken".owner = "z";
      # Default owner (root) is fine — the adguardhome-sync systemd service
      # runs as root, no User= override.
      "adguardhome-sync/originPassword" = { };
      "adguardhome-sync/routerPassword" = { };
      # Raw keyfile for all seven array members (slot 0; every disk also
      # carries the fleet recovery passphrase in slot 1). `format = "binary"`
      # is the byte-exact round-trip for raw key material.
      "luks/arrayKeyFile" = {
        format = "binary";
        sopsFile = ../../secrets/galactica-array.key;
      };
    };
  };

  # smartd across the twelve-plus real disks; smart.nix ships the package.
  homelab.smart.monitor = true;

  # Flipped after staging issuance was proven (which is what the flag is
  # for). Separate cert storage per CA, so this is freely reversible.
  homelab.letsencryptStaging = false;

  # ── NFS server (re-exports the array to memory-alpha) ──────────────────────
  # 2049 only: memory-alpha mounts nfsvers=4. No export carries `fsid=0`, so
  # there is no pseudo-root and clients mount the full path, as under Unraid.
  #
  # ⚠ fsids 100 (`arr_media`) and 102 (`arr_managed_data`) are deliberately NOT
  # exported and stay reserved — reusing a number for different content hands a
  # client ESTALE. MANUAL-STEPS §8 has the table and the reasoning; scope and
  # `rw` are transcribed from the decision there, not re-decided here.
  services.nfs.server.enable = true;
  services.nfs.server.exports = ''
    # The *arr library. Thin until the staged media is imported — that is the
    # import pending, not a broken mount.
    /tank/nixflix_media/media     192.168.8.0/24(rw,sync,no_subtree_check,fsid=104)

    # The hand-curated library the *arrs do not manage — hence the client's
    # mountpoint name. Same share and consumer as under Unraid; path moved.
    /tank/media_staging/jellyfin  192.168.8.0/24(rw,sync,no_subtree_check,fsid=101)

    # Consumer unconfirmed (SHARES.md §4) — why the scope is LAN-wide.
    /tank/bambuddy_library        192.168.8.0/24(rw,sync,no_subtree_check,fsid=103)
  '';
  networking.firewall.allowedTCPPorts = [ 2049 ];

  # ── home-manager ──────────────────────────────────────────────────────────
  home-manager = {
    useGlobalPkgs = true;
    useUserPackages = true;
    users.z = import ./home.nix;
  };

  system.stateVersion = "26.05";
}
