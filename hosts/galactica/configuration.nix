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
    ../../modules/nixos/traefik-galactica.nix
    ./borgmatic.nix
    ./nixflix.nix
    ./unpackerr.nix
    ./bazarr.nix
  ];

  networking.hostName = "galactica";
  networking.networkmanager.enable = true;

  # BIOS SOL covers POST and the bootloader only — the kernel needs its own
  # console= or SOL goes dark when it takes over (live-iso.nix, PLATFORM.md §2).
  homelab.serialConsole.device = "ttyS1,115200n8";

  # (`tower.internal` resolves here via an AdGuard rewrite on hopper, not via
  # anything in this file — DECISIONS.md §2.)

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
