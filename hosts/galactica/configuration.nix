{ config, pkgs, lib, ... }:

# ─────────────────────────────────────────────────────────────────────────────
# galactica — Tower, bare-metal NixOS (Supermicro X9SCM-F, ex-Unraid).
# ─────────────────────────────────────────────────────────────────────────────
# Root is LUKS + btrfs on the NVMe (hosts/galactica/disko.nix), matching every
# other host in the fleet — NOT ZFS. ZFS lives in `tank`, the RAIDZ1 media
# array (4× 12 TB LUKS spinners + a 3-way-mirror LUKS SSD special vdev),
# built live 2026-09-01 and declared below (crypttab + import ordering) — see
# DECISIONS.md §7 for why the two encryption/filesystem stories are kept
# separate, and MANUAL-STEPS.md §9 for the build record.
#
# ⚠ /boot is on the WD Blue's ESP, NOT the NVMe or midden — this board's
# firmware can't UEFI-boot the NVMe or anything behind the LSI HBA, and the
# working NVRAM entry is hand-owned. hardware-configuration.nix's header has
# the full story; it's why canTouchEfiVariables is false below.

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
    ./borgmatic.nix
    ./media.nix
    ./anime.nix
  ];

  networking.hostName = "galactica";
  networking.networkmanager.enable = true;

  # Same reasoning as live-iso.nix: BIOS-level IPMI SOL redirection (Tower's
  # BMC, ttyS1 @ 115200 by Supermicro X9 convention, PLATFORM.md §2) only
  # covers POST and the bootloader — the kernel needs its own console=
  # parameter or SOL goes dark the instant it takes over. Missing here was a
  # real gap, not a hypothetical: it's why SOL showed ISOLINUX and the
  # systemd-boot menu fine but nothing from the kernel or the initrd
  # onward on the very first real boot, forcing the LUKS unlock over SSH
  # instead (which worked, but was never supposed to be the only option).
  homelab.serialConsole.device = "ttyS1,115200n8";

  # `tower.internal` keeps resolving to this host via an AdGuard rewrite on
  # hopper, not via the hostname — DECISIONS.md §2. Nothing to configure here;
  # the rewrite lives in hopper's dns.nix, pointed at whatever DHCP hands this
  # box. Static reservation on the router is the intended mechanism, not a
  # static IP in this config.

  # Mandatory for ZFS — its absence fails late and confusingly (DECISIONS.md
  # §7 implementation notes). Derived from the hostname
  # (`sha256sum <<<"galactica.internal" | head -c8`) rather than pulled from
  # thin air, so it's reproducible if this file is ever regenerated, but it
  # carries no other meaning — ZFS just wants 8 stable hex digits.
  networking.hostId = "f9e250c9";

  boot.loader.systemd-boot.enable = true;
  # ⚠ FALSE, deliberately — see hardware-configuration.nix's /boot header. This
  # board's AMI BIOS boots ONLY the removable-media fallback
  # (`\EFI\BOOT\BOOTX64.EFI`), never the `\EFI\systemd\` path NixOS would
  # register in NVRAM. So the working boot entry ("galactica-wdblue", a
  # partition-signature path to the fallback) is created and owned by hand;
  # letting NixOS touch EFI variables just re-adds an unbootable `\EFI\systemd\`
  # entry every `switch` that the firmware then prunes at POST. `bootctl` still
  # keeps the `\EFI\BOOT\BOOTX64.EFI` file itself current on each switch.
  boot.loader.efi.canTouchEfiVariables = false;

  # ── ZFS (the RAIDZ1 array, built separately — see the header note) ─────────
  boot.supportedFilesystems = [ "zfs" ];
  boot.zfs.forceImportRoot = false; # root is btrfs, not ZFS — nothing to force here
  services.zfs.autoScrub = {
    enable = true;
    interval = "monthly";
  };
  # Periodic zpool trim — needed for the special vdev's deliberate
  # overprovisioning (420 GB partitions on disks with 447-477 GiB raw) to
  # actually pay off. Discards must also pass the LUKS layer underneath each
  # member disk (`settings.allowDiscards = true` on each, once those are
  # wired up alongside the pool itself) or they get silently dropped at the
  # dm-crypt layer.
  services.zfs.trim = {
    enable = true;
    interval = "weekly";
  };

  # ── tank import ordering (LUKS-under-ZFS) — the three gotchas the opus
  # review flagged for this exact moment (MANUAL-STEPS.md §9) ─────────────────
  # tank's members live under /dev/mapper (dm-crypt), opened in stage-2 by the
  # crypttab above — so import must (a) scan /dev/mapper, not the by-id default,
  # or it finds nothing; (b) run only AFTER cryptsetup.target, or on a cold
  # boot it races the seven LUKS opens and imports a degraded/absent pool; and
  # (c) be driven by extraPools, because tank's datasets use native ZFS
  # mountpoints (/tank/*) rather than fileSystems.* entries, so nothing else
  # would trigger the import at boot. Cold-boot verified 2026-09-01.
  boot.zfs.devNodes = "/dev/mapper";
  boot.zfs.extraPools = [ "tank" ];
  systemd.services."zfs-import-tank" = {
    after = [ "cryptsetup.target" ];
  };

  # Low-swappiness swap partition (disko.nix) — a pressure release valve, not
  # a memory tier. 32 GB RAM and a mostly-sequential media workload means
  # this should rarely if ever actually get used.
  boot.kernel.sysctl."vm.swappiness" = 10;

  # ── /var/log/journal on midden (disko.nix: disk.midden) ─────────────────────
  # Not root, so no initrd unlock — same reasoning DECISIONS.md §7 already
  # applied to every other data disk on this host. Unlocked automatically
  # during normal boot via a sops-provisioned keyfile, matching DESIGN.md's
  # own description of the array's disks: "sops-nix keyfiles decrypt at
  # boot ... and /etc/crypttab opens the pools." No manual passphrase entry —
  # this is disposable data, not the thing worth adding a step to protect.
  #
  # ⚠ Only `cryptlogs` needs this — `midden`'s other partition
  # (`/var/cache/nix-build`) is deliberately NOT encrypted at all (reversed
  # 2026-08-31, owner's challenge after disko had already formatted it
  # encrypted, fixed while still empty). See disko.nix's `nixBuildScratch`
  # comment for why the two partitions don't actually share a rationale
  # despite both being disposable — logs routinely pick up incidentally
  # sensitive content, Nix build scratch structurally shouldn't ever hold
  # anything the Nix store itself doesn't already expose unencrypted.
  #
  # ✅ UUID confirmed 2026-08-31 via `blkid` post-disko; keyfile generated,
  # registered, and stored as `luks/middenKeyFile` (MANUAL-STEPS.md §4, done).
  #
  # `,discard` at the end — without it dm-crypt silently drops every TRIM,
  # and the whole point of `allowDiscards`/weekly `zpool trim` elsewhere in
  # this design is defeated. disko's own `allowDiscards = true` only ever
  # emits `boot.initrd.luks.devices.*.allowDiscards`, which is meaningless
  # for a non-initrd device and moot anyway since disko.nix isn't imported
  # live — this crypttab option is the only place it actually takes effect.
  # (In practice disko's live run also opened this with `cryptsetup
  # --persistent`, which stores the discard flag in the LUKS2 header itself
  # — a second, independent path to the same effect, not a substitute for
  # this one.) `nofail` since a missing keyfile or unplugged disk on some
  # future boot should degrade gracefully rather than hold up the machine.
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

  # Nix's build sandboxes/scratch directories, kept off the NVMe root disk —
  # a package or kernel build's transient I/O has no business wearing down
  # the drive everything else depends on, and this data is recreated fresh
  # every build regardless. `build-dir` confirmed as a real, current Nix
  # setting (nix show-config, 2.34.8) — not to be confused with
  # `sandbox-build-dir`, which is the path *inside* the sandbox and isn't
  # what controls where scratch space actually lives on disk.
  nix.settings.build-dir = "/var/cache/nix-build";

  # Container logs default to /var/lib/docker/containers/*/*.json (still on
  # the NVMe, untouched by the /var/log/journal mount above) unless
  # redirected — and they're almost certainly the bulk of this host's log
  # volume once the *arr stack/Immich/etc. are running. Routing through
  # journald means they land on the dedicated logs disk via the same
  # mechanism as everything else, instead of only catching half the story.
  # Confirmed correct option path/syntax and confirmed `journald` is a valid
  # Docker log driver (opus review, rendered daemon.json directly).
  virtualisation.docker.daemon.settings.log-driver = "journald";

  # common.nix's fleet-wide SystemMaxUse=500M/MaxRetentionSec=2week would
  # waste 47.5 of the 48G partition given to exactly this — `mkAfter`, not
  # `mkForce`, since journald.conf is last-key-wins and this should extend
  # the fleet default rather than silently drop it (a host that later stops
  # importing this override should fall back to the sane default, not to
  # nothing). 32G leaves real headroom on the partition; 180 days is
  # generous now that space isn't the binding constraint.
  services.journald.extraConfig = lib.mkAfter ''
    SystemMaxUse=32G
    MaxRetentionSec=180day
  '';

  # ── LUKS SSH unlock (root only — see DECISIONS.md §7 on why data disks
  # don't get this) ───────────────────────────────────────────────────────────
  # The shared flow lives in modules/nixos/luks-remote-unlock.nix (imported
  # above). Only the host-specific piece stays here:
  #
  # ✅ Confirmed 2026-08-31 directly on Tower (`readlink -f
  # /sys/class/net/*/device/driver`): `e1000e`, matching PLATFORM.md's
  # documented Intel 82574L — checked rather than assumed, same as every
  # other host's initrd-NIC fix in this fleet.
  boot.initrd.availableKernelModules = lib.mkAfter [ "e1000e" ];

  # ── Monitoring agents — report galactica to memory-alpha ────────────────────
  # Both hubs run on memory-alpha: the Beszel hub as a Docker stack
  # (homelab-stacks memory-alpha/monitoring, beszel.monitor.zjones.dev) and the
  # Arcane manager via NixOS (modules/nixos/arcane.nix, arcane.memory-alpha
  # .internal). Neither is on hopper — the old modules/nixos/{beszel,ntfy}.nix
  # are hopper-shaped and unused. So both agents here dial memory-alpha, which
  # is always-on; nothing depends on backburnered hopper.
  #
  # ⚠ OWNER STEPS before this activates (add the secrets, then `nrs`):
  #   Beszel: on memory-alpha's hub, "Add system" → copy the shared KEY and the
  #     per-agent TOKEN. `sops secrets/galactica.yaml`: add `beszel/hubKey`
  #     (the KEY) and `beszel/agentToken` (the TOKEN), raw values, no prefixes.
  #   Arcane: on the memory-alpha manager, Settings → Environments → add
  #     galactica → copy the AGENT_TOKEN. Add it as `arcane/agentToken`.
  services.beszelAgent = {
    enable = true;
    keyFile = config.sops.secrets."beszel/hubKey".path;
    tokenFile = config.sops.secrets."beszel/agentToken".path;
    # hubUrl / port / image default to the fleet's values — see beszel-agent.nix.
  };

  # Edge mode: dials out to the manager, no inbound port needed. The .zjones.dev
  # name carries a valid LE cert (vs. the self-signed .internal one), so the
  # agent's TLS to the manager just works over split-horizon DNS.
  services.arcaneAgent = {
    # managerUrl defaults to the fleet manager — see arcane-agent.nix.
    enable = true;
    tokenFile = config.sops.secrets."arcane/agentToken".path;
  };

  # SMART history for the array's 12 disks -> the Scrutiny hub on memory-alpha.
  # Complements homelab.smart.monitor (smartd alerts locally); this is the
  # trend history and the web view smartd does not give.
  services.scrutinyCollector.enable = true;

  # ── NUT — galactica is the server, UPS attached directly ───────────────────
  # DECISIONS.md's "Reversed by the move to bare metal": under bare metal the
  # UPS plugs into this host directly (no VFIO passthrough problem to work
  # around), and memory-alpha becomes a client via modules/nixos/nut-client.nix.
  #
  # Deliberately NOT `modules/nixos/nut.nix` — despite living in modules/,
  # that file is hopper's own specific server config (hardcoded UPS
  # description, driver, ntfy routing for hopper's rack UPS), not a generic
  # template. This host has a different, physically separate UPS.
  #
  # ⚠ NOT YET CONFIRMED: driver/port for Tower's actual UPS. Run
  # `nut-scanner -U` on the real machine and fill in below — placeholder
  # values are commented out rather than guessed, since a wrong driver name
  # fails at service-start, not at eval time, and would be easy to miss.
  #
  # ⚠ The UPS name (`ups`) and monitor user (`monuser`) below are NOT
  # arbitrary — an opus review agent caught that an earlier draft named them
  # `tower`/`upsmon`, which would silently fail to connect: they must match
  # modules/nixos/nut-client.nix EXACTLY, since that module is already live
  # on memory-alpha and hardcodes `system = "ups@tower.internal"` and
  # `user = "monuser"`. Also needs the NUT protocol port actually opened —
  # nothing did, before.
  #
  # power.ups = {
  #   enable = true;
  #   mode = "netserver";
  #   ups.ups = {
  #     driver = "CONFIRM_ME_LIVE"; # nut-scanner -U
  #     port = "auto";
  #     description = "Tower UPS";
  #   };
  #   upsd.listen = [ { address = "0.0.0.0"; } ]; # memory-alpha needs LAN access, unlike hopper's local-only default
  #   upsmon.monitor.local = {
  #     system = "ups@localhost";
  #     type = "primary";
  #     user = "monuser";
  #     passwordFile = config.sops.secrets."nut/upsmonPassword".path;
  #   };
  #   users.monuser = {
  #     passwordFile = config.sops.secrets."nut/upsmonPassword".path;
  #     upsmon = "primary";
  #   };
  # };
  # sops.secrets."nut/upsmonPassword" = {};
  # ⚠ When uncommenting: add 3493 into the EXISTING `networking.firewall.
  # allowedTCPPorts = [ 2049 ];` list further down (NFS server section),
  # don't declare this attribute a second time — two definitions of the
  # exact same option path in one file's attrset is a hard duplicate-key
  # eval error, the same class of bug the crypttab mkIf mistake was.
  # networking.firewall.allowedTCPPorts = [ 3493 ]; # NUT protocol — memory-alpha's client needs this reachable

  # ── sops-nix ────────────────────────────────────────────────────────────────
  # x86_64, builds its own closure (unlike hopper/hamilton, which need
  # memory-alpha as aarch64 build+validation host) — so per DECISIONS.md §4
  # the recipients are *admin + *galactica, both in .sops.yaml since first boot.
  sops = {
    defaultSopsFile = ../../secrets/galactica.yaml;
    age.sshKeyPaths = [ "/etc/ssh/ssh_host_ed25519_key" ];
    secrets = {
      # Raw keyfile for midden (see the crypttab block above) — not
      # a passphrase, generated once with `head -c 4096 /dev/urandom` and
      # registered against the LUKS header with `cryptsetup luksAddKey`.
      "luks/middenKeyFile" = { };
      # Monitoring-agent secrets (see the services.beszelAgent/arcaneAgent
      # blocks). owner = "z" so each agent's compose invocation can read them;
      # created by the owner after registering galactica in each memory-alpha hub.
      "beszel/hubKey".owner = "z";
      "beszel/agentToken".owner = "z";
      "arcane/agentToken".owner = "z";
      # Raw 4096-byte keyfile unlocking all seven ZFS-array LUKS members
      # (slot 0; each disk also carries the fleet recovery passphrase in slot
      # 1, so the boot never depends solely on this). Stored as a dedicated
      # `format = "binary"` sops file rather than a value inside galactica.yaml
      # — binary format is the reliable byte-exact round-trip for raw key
      # material. sha256 verified against the luksFormat-time hash
      # (6fbbd614…fca930) and proven across a cold boot, 2026-09-01.
      "luks/arrayKeyFile" = {
        format = "binary";
        sopsFile = ../../secrets/galactica-array.key;
      };
    };
  };

  # Twelve-plus real disks (array, special vdev pairs, root NVMe) once the
  # array exists — smartd has plenty to poll. modules/nixos/smart.nix ships
  # the package fleet-wide regardless; this turns on monitoring.
  homelab.smart.monitor = true;

  # ── NFS server (re-exports the array to memory-alpha) ──────────────────────
  # `exports` still to come with the §8 cutover (fsids 100-103). 2049 only:
  # memory-alpha mounts nfsvers=4, which needs no rpcbind/mountd/statd spread.
  services.nfs.server.enable = true;
  networking.firewall.allowedTCPPorts = [ 2049 ];

  # ── home-manager ──────────────────────────────────────────────────────────
  home-manager = {
    useGlobalPkgs = true;
    useUserPackages = true;
    users.z = import ./home.nix;
  };

  system.stateVersion = "26.05";
}
