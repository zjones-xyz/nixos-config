{ config, pkgs, lib, ... }:

# ─────────────────────────────────────────────────────────────────────────────
# galactica — Tower, bare-metal NixOS.
# ─────────────────────────────────────────────────────────────────────────────
# NOT YET WIRED INTO flake.nix. `hardware-configuration.nix` (imported below)
# does not exist yet — it can only be generated live, on the real machine,
# booted from the install ISO (`nixos-generate-config --no-filesystems --root
# /mnt` after disko.nix has partitioned the NVMe). Adding this to
# `nixosConfigurations` before that file exists would break `nix flake check`
# for an import that can never resolve outside the real hardware. Add the
# flake.nix entry and the secrets/galactica.yaml .sops.yaml staging (see the
# sops-nix section below) as the last step of the install, once
# hardware-configuration.nix is real.
#
# What's settled vs. still needs live confirmation on the actual machine is
# marked inline as it comes up — see also MANUAL-STEPS.md for the consolidated
# checklist.
#
# Root is LUKS + btrfs (hosts/galactica/disko.nix), matching every other host
# in the fleet — NOT ZFS. The RAIDZ1 media array is where ZFS lives on this
# host; see DECISIONS.md §7 for why the two encryption/filesystem stories are
# deliberately kept separate. The array itself isn't declared here yet: it
# doesn't exist until built live (`zpool create ...`, migration handoff step
# 8), and its datasets/mountpoints land in a follow-up commit once that's done
# and their names are settled — same "no config for a layout that doesn't
# exist yet" reasoning as DECISIONS.md §3 already applied to this whole host.

let
  # secrets/galactica.yaml does not exist in the repo yet — created after
  # first boot, same gating pattern as hosts/pegasus/configuration.nix. Until
  # then this evaluates cleanly with sops-dependent bits disabled.
  hasSops = builtins.pathExists ../../secrets/galactica.yaml;
in
{
  imports = [
    ./hardware-configuration.nix
    ../../modules/nixos/common.nix
    ../../modules/nixos/btrfs-snapshots.nix
    ../../modules/nixos/serial-console.nix
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
  boot.loader.efi.canTouchEfiVariables = true;

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
  # ✅ UUID confirmed 2026-08-31 via `blkid` post-disko.
  #
  # ⚠ NOT YET DONE: the keyfile itself. Generate with
  # `head -c 4096 /dev/urandom > midden-keyfile`, register it with
  # `cryptsetup luksAddKey`, then `sops secrets/galactica.yaml` and add it
  # as `luks/middenKeyFile` (MANUAL-STEPS.md §4).
  #
  # ⚠ `.text` must be set INSIDE the mkIf, not mkIf applied to `.text` — an
  # opus review agent caught this: environment.etc's submodule forces
  # `.source` (derived from `.text`) unconditionally once the entry exists at
  # all, so `environment.etc."crypttab".text = lib.mkIf hasSops "...";`
  # still instantiates the entry and fails eval with `hasSops = false`
  # ("option `environment.etc.crypttab.source' was accessed but has no value
  # defined") — the exact state this config is in right now. Confirmed by
  # evaluating both branches directly.
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
  environment.etc."crypttab" = lib.mkIf hasSops {
    text = ''
      cryptlogs UUID=b44e545c-b4b3-4037-a263-d5a522933b37 ${config.sops.secrets."luks/middenKeyFile".path} luks,discard,nofail
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
  # Same shape as memory-alpha/pegasus — see memory-alpha/configuration.nix
  # for the full writeup of why each piece exists.
  #
  # ✅ Confirmed 2026-08-31 directly on Tower (`readlink -f
  # /sys/class/net/*/device/driver`): `e1000e`, matching PLATFORM.md's
  # documented Intel 82574L — checked rather than assumed, same as every
  # other host's initrd-NIC fix in this fleet.
  boot.initrd.systemd.enable = true;
  boot.initrd.availableKernelModules = lib.mkAfter [ "e1000e" ];

  boot.initrd.network = {
    enable = true;
    ssh = {
      enable = true;
      port = 2222;
      authorizedKeys = [
        "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQCfTHdojQvKOlTaaTYT2RmYMNKQ/6rBQwn6V+bPnrtASaI/G5E7RW67XGbZHi3K7EctyB9UP9Uw54sayEu4ebixI/dNFVVWeZ2byBQ49FoXh5o9Cfok0Qwf0QM7g9Td8O6Iu2ElnI8e+9cr8ThrfPpKmP68e6mpuYDvhQb4omcx8kRhxnsuNxkL2xCTNVxG/jw68o/1KHX++6tRqf0E3PBCjZ3Z8HMTdS8ouEBa8Y96GGeUvslwDJ9cUtLNCUhR5t3mGu3iSS9RYpFg/JujyTT9yhe2O/0og+OhBeSayGZMOXGWngGUEItExlbq2I4rMV5pFB1q+OyqksvlUfkJ/j3yJOii5uwonYvkWLZfR02yhn2b/bgOfYaimO5rfKj5jAC8bMRnWqLJAiG2qRDwtJT+ijyYlTKgLpz73sOGAQVvZygq11Vc35cZMFojlMeqAHdZMGi6XkUHnfZt8gyplw6VPV5EQnyDI4bRfY9sknuFvjHqdEzNyNrIEXtlmIB870s= z@Serenity.local"
        # Added 2026-08-31, live — the initrd unlock config was copied
        # verbatim from memory-alpha/pegasus, both of which have this exact
        # same gap: common.nix already grants pegasus's key access to the
        # normal system's z user, but this list is separate and only ever
        # had serenity's key. Found by hitting "Permission denied" trying
        # to unlock from pegasus on the first real boot.
        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAICjzi98Mik0CUMxSpUBf7+LA8co0grMtDb5NqwhVZ7nF z@pegasus"
      ];
      hostKeys = [ "/etc/secrets/initrd/ssh_host_ed25519_key" ];
    };
  };

  # `networking.networkmanager.enable = true` implicitly sets
  # `networking.useDHCP = false`, which is exactly what gates nixpkgs' own
  # auto-generated initrd DHCP `.network` unit — without an explicit one, the
  # NIC comes up at link layer in the initrd SSH-unlock stage above and never
  # gets an address, so `ssh -p 2222` just times out, indistinguishable from
  # the `e1000e` guess being wrong. memory-alpha already carries this fix;
  # pegasus does not — an opus review agent caught that this file had copied
  # pegasus's shape rather than memory-alpha's, and that the gap matters more
  # here since galactica is headless (pegasus has a display to fall back on,
  # plausibly why it was never noticed there). Generic match rather than
  # MAC-pinned like memory-alpha's, since this host has one onboard NIC with
  # no renaming scheme to keep consistent with.
  boot.initrd.systemd.network.networks."99-ethernet-default-dhcp" = {
    matchConfig = {
      Type = "ether";
      Kind = "!*";
    };
    DHCP = "yes";
  };

  # Same NetworkManager/initrd-DHCP interaction every x86_64 host in this
  # fleet has hit — see pegasus/memory-alpha's configuration.nix for the full
  # explanation. Without this: routing works, DNS is empty, every boot.
  # Widened 2026-08-31 after the original (address-flush-only) version
  # provably never fixed DNS on this host — NetworkManager still showed
  # enp0s25 as "connected (externally)" every boot, with an empty
  # /etc/resolv.conf. Three changes bundled into one attempt rather than
  # three separate reboot cycles:
  #   1. A kmsg marker, so a future "did this even run" question is
  #      answerable without relying on journal transfer across
  #      switch-root — this is the one piece of real evidence this
  #      debugging session was missing.
  #   2. Stop systemd-networkd outright, not just remove its address —
  #      NetworkManager may be deferring to a still-active DHCP client
  #      independent of what `ip addr` shows.
  #   3. Bring the link administratively down, not just flush its
  #      address — NetworkManager's "externally configured" heuristic may
  #      key off the link already being UP at NM startup, which a plain
  #      address flush never touched.
  boot.initrd.systemd.services.flush-network-before-switch-root = {
    description = "Flush initrd DHCP state so NetworkManager re-negotiates DNS";
    before = [ "initrd-switch-root.target" ];
    wantedBy = [ "initrd-switch-root.target" ];
    unitConfig.DefaultDependencies = false;
    serviceConfig.Type = "oneshot";
    path = [ pkgs.iproute2 pkgs.gawk pkgs.systemd ];
    script = ''
      echo "flush-network-before-switch-root: starting" > /dev/kmsg || true
      systemctl stop systemd-networkd.service || true
      for iface in $(ip -o link show type ether | awk -F': ' '{print $2}'); do
        ip addr flush dev "$iface" || true
        ip link set dev "$iface" down || true
      done
      echo "flush-network-before-switch-root: done" > /dev/kmsg || true
    '';
  };
  boot.initrd.systemd.storePaths = [ "${pkgs.iproute2}/bin/ip" ];

  boot.initrd.systemd.services.chime-waiting-unlock = {
    description = "Chime: initrd SSH unlock server ready";
    after = [ "sshd.service" ];
    wantedBy = [ "initrd.target" ];
    before = [ "shutdown.target" ];
    conflicts = [ "shutdown.target" ];
    unitConfig.DefaultDependencies = false;
    serviceConfig.Type = "oneshot";
    path = [ pkgs.coreutils ];
    script = ''
      for i in 1 2 3; do
        printf '\a' > /dev/console
        sleep 0.15
      done
    '';
  };

  boot.initrd.systemd.services.chime-unlock-finished = {
    description = "Chime: LUKS unlock finished";
    after = [ "cryptsetup.target" ];
    wantedBy = [ "initrd.target" ];
    before = [ "shutdown.target" ];
    conflicts = [ "shutdown.target" ];
    unitConfig.DefaultDependencies = false;
    serviceConfig.Type = "oneshot";
    path = [ pkgs.coreutils ];
    script = ''
      for i in 1 2; do
        printf '\a' > /dev/console
        sleep 0.5
      done
    '';
  };

  # ── Beszel agent — NOT YET WIRED ────────────────────────────────────────────
  # DESIGN.md's Phase 2 step 8 calls for "a Beszel agent (modules/nixos/beszel.nix
  # — the hub already runs on hopper)", but that file turns out to be hopper's
  # own hub+agent bundle: hardcoded `beszel.hopper.internal` Traefik hostnames
  # and a dependency on hopper's own `docker-proxy-network`/`traefik-docker`
  # units. Importing it here would try to stand up a second, redundant hub
  # rather than just an agent pointed at hopper's existing one. Needs a real
  # agent-only unit (same `henrygd/beszel-agent` container, host network mode,
  # KEY env pointed at hopper's hub) written for this host specifically — see
  # MANUAL-STEPS.md. Left undone rather than guessed at.

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
  # memory-alpha as aarch64 build+validation host) — so per DECISIONS.md §4,
  # this needs *admin only until first boot, then *galactica is added and
  # `sops updatekeys secrets/galactica.yaml` re-run.
  sops = lib.mkIf hasSops {
    defaultSopsFile = ../../secrets/galactica.yaml;
    age.sshKeyPaths = [ "/etc/ssh/ssh_host_ed25519_key" ];
    # Raw keyfile for midden (see the crypttab block above) — not
    # a passphrase, generated once with `head -c 4096 /dev/urandom` and
    # registered against the LUKS header with `cryptsetup luksAddKey`.
    secrets."luks/middenKeyFile" = { };
  };

  # Twelve-plus real disks (array, special vdev pairs, root NVMe) once the
  # array exists — smartd has plenty to poll. modules/nixos/smart.nix ships
  # the package fleet-wide regardless; this turns on monitoring.
  homelab.smart.monitor = true;

  # ── NFS server (re-exports the array to memory-alpha) ──────────────────────
  # Enabling the server and opening its port don't depend on the array
  # existing, so this lands now — the actual `services.nfs.server.exports`
  # content is still blocked on the array's dataset paths and lands with
  # that config. See MANUAL-STEPS.md §8 for the fsid-preservation plan this
  # is in service of.
  #
  # 2049 only: both of memory-alpha's mounts specify nfsvers=4, and NFSv4
  # doesn't need the rpcbind/mountd/statd port spread NFSv3 requires.
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
