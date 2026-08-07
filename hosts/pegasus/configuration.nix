{ config, pkgs, lib, ... }:

let
  # secrets/pegasus.yaml does not exist in the repo yet — it must be created by
  # Zoe (see hosts/pegasus/SECRETS-TODO.md). The sops + tailscale-authKey wiring
  # below is gated on the file's presence so the closure evaluates cleanly until
  # then, and activates automatically once the encrypted file is committed.
  hasSops = builtins.pathExists ../../secrets/pegasus.yaml;
in
{
  imports = [
    ./hardware-configuration.nix
    ../../modules/nixos/common.nix
    ../../modules/nixos/nvidia.nix
    ../../modules/nixos/desktop-plasma.nix
    ../../modules/nixos/desktop-cosmic.nix
    ../../modules/nixos/desktop-dragonized.nix
    ../../modules/nixos/gaming.nix
    ../../modules/nixos/performance.nix
    ../../modules/nixos/btrfs-snapshots.nix
    ../../modules/nixos/ollama.nix
    ../../modules/nixos/yubikey.nix
    ../../modules/nixos/nzxt-kraken.nix
    ../../modules/nixos/keyboards.nix
    ../../modules/nixos/mouse-tools.nix
    # TEMPORARY — liskov VFIO bring-up test, see the homelab.vfio block below
    # and hosts/liskov/DEPLOY.md §2b-bis. Remove with that block.
    ../../modules/nixos/vfio.nix
    # olla-router.nix is DISABLED for now (2026-07-11): its build runs olla's
    # own Go test suite, and pkg/eventbus's TestEventBus_HighVolumePublishing
    # is a wall-clock throughput assertion that fails under the Nix sandbox's
    # constrained/throttled CPU scheduling (expects >=1000 of 100k events
    # delivered, got 220) — not a real defect in what we're packaging. Fastest
    # unblock was skipping Olla entirely; ollama.nix works standalone (binds
    # 127.0.0.1 only, no hard dependency on the router). To bring Olla back:
    # either re-add this import with `doCheck = false;` set on the
    # `olla = pkgs.buildGoModule` derivation in olla-router.nix (skips
    # upstream's test suite, standard for packaging binaries we don't
    # maintain), or file the flakiness upstream first.
    # ../../modules/nixos/olla-router.nix
  ];

  networking.hostName = "pegasus";
  networking.networkmanager.enable = true;

  # ── VFIO bring-up test (TEMPORARY) ──────────────────────────────────────────
  # Not a pegasus feature. modules/nixos/vfio.nix has never run on real
  # hardware, and the mechanism it depends on was documented wrongly until
  # recently: listing vfio_pci in boot.initrd.kernelModules does NOT order it
  # ahead of udev under the systemd initrd that 26.05 uses by default, so the
  # softdep lines are what actually win the race against ahci. That has been
  # reasoned about and never observed.
  #
  # Observing it here costs one reboot. Observing it on liskov means finding out
  # on the host whose array controller is the device being bound.
  #
  # Safe on this machine because pegasus boots from NVMe and `1b21:` matches
  # only the ASMedia add-in cards — never its onboard SATA (AMD, `1022:`) nor
  # the 4070 (`10de:`). Adding either of those here is pegasus's equivalent of
  # the `8086:` guard that liskov's invariant check enforces. Do not.
  #
  # ⚠ Remove this block and the vfio.nix import once the ASM1166 goes back to
  # liskov. Leaving it binds a card pegasus may later want to actually use.
  homelab.vfio = {
    enable = true;
    # NOT the "intel" default — pegasus is AM4. The wrong value is silently
    # ignored and presents exactly like AMD-Vi being disabled in firmware.
    cpuVendor = "amd";
    pciIds = [
      "1b21:1166" # ASM1166 SATA — competitor driver is ahci. The result that matters.
      # Only if the ASM1042 travelled too (it tests the xhci_pci softdep, which
      # may turn out to be defensive-only — see DEPLOY.md §4c):
      # "1b21:1042"
    ];
  };

  # NOT temporary — keep this when the homelab.vfio block above comes out.
  #
  # Added because the bring-up test's only verification step is
  # `lspci -nnk -d 1b21:1166`, and pegasus had no lspci at all, which made the
  # test unrunnable on the machine it was written for. liskov already carries
  # pciutils for the same reason (hosts/liskov/configuration.nix). It belongs in
  # environment.systemPackages rather than home.packages so that `sudo lspci`
  # resolves — sudo does not inherit the user profile's PATH.
  environment.systemPackages = with pkgs; [
    pciutils
  ];

  # ── Boot ────────────────────────────────────────────────────────────────────
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  # Stock latest mainline kernel (NOT a CachyOS/Chaotic kernel). sched-ext is
  # upstream since 6.12, so the stock kernel is all scx needs — see
  # modules/nixos/performance.nix. If the NVIDIA production driver ever lags the
  # bleeding-edge kernel, drop this line to fall back to the default kernel
  # (still >= 6.12). See hosts/pegasus/DECISIONS.md.
  boot.kernelPackages = pkgs.linuxPackages_latest;

  # Fleet default (modules/nixos/common.nix) reboots 10s after a panic. Pegasus
  # has a physical display attached, so widen that to 600s — enough time to
  # walk over and read/photograph the panic screen before it auto-reboots and
  # the evidence is gone.
  boot.kernel.sysctl."kernel.panic" = lib.mkForce 600;

  # ── Tailscale ───────────────────────────────────────────────────────────────
  # Pegasus is reached over the tailnet (it is the primary GPU inference
  # endpoint — see modules/nixos/olla-router.nix). It is NOT an exit node, so we
  # do not reuse the hopper-flavoured modules/nixos/tailscale.nix here.
  services.tailscale = {
    enable = true;
    extraUpFlags = [ "--ssh" ];
    # Headless auth key, provisioned via sops once secrets/pegasus.yaml exists.
    # Until then, run `tailscale up` once interactively on first boot.
    authKeyFile = lib.mkIf hasSops config.sops.secrets."tailscale/authKey".path;
  };
  networking.firewall.trustedInterfaces = [ "tailscale0" ];
  networking.firewall.allowedUDPPorts = [ config.services.tailscale.port ];

  # ── Remote Desktop (xrdp) ────────────────────────────────────────────────────
  # SUPERSEDED KRDP (KWin's built-in RDP server) — see DECISIONS.md. KRDP only
  # shares an already-live, already-logged-in KWin session; upstream KDE has
  # confirmed it has no headless mode and no plans for one, which ruled it out
  # for "reach a working desktop after any reboot/logout without walking over
  # or needing the IP-KVM." xrdp + its bundled xorgxrdp backend (this
  # nixpkgs's `xrdp` package already excludes every other sesman backend and
  # keeps only `[Xorg]`) spins up an independent Xorg/Plasma-X11 session per
  # RDP connection — decoupled from SDDM and whatever's on the physical seat,
  # so it works the same whether the console is at the greeter, locked, or
  # logged out. Trade-off: it's Plasma over X11, a second session, not a
  # mirror of the physical Wayland one.
  #
  # No `openFirewall` and no bind-address config: tailscale0 is already a
  # trustedInterfaces member (see the Tailscale block above), so xrdp rides
  # the exact same tailnet-only boundary SSH already uses, the same reasoning
  # as the superseded KRDP attempt — the NixOS xrdp module has no per-interface
  # bind option, so this is enforced at the firewall, not the listen socket.
  #
  # Auth is PAM against z's actual account password (the same
  # sops-provisioned `z/hashedPassword` secret used for console/SDDM login,
  # see the sops block below) — no separate credential to provision.
  services.xrdp = {
    enable = true;
    defaultWindowManager = "${pkgs.kdePackages.plasma-workspace}/bin/startplasma-x11";
  };

  # ── LUKS SSH unlock ─────────────────────────────────────────────────────────
  # Lets you decrypt the drive remotely (e.g. `unlock-pegasus` from serenity)
  # instead of needing to be physically at the box after every reboot. Mirrors
  # hosts/memory-alpha/configuration.nix's setup — see that file for the full
  # writeup of *why* each piece exists — simplified here since pegasus has one
  # stock onboard NIC (no USB dongles to rename/re-drive).
  #
  # Setup step required before this can build (does NOT block the current
  # install — only the next `nixos-rebuild switch` that picks up this change):
  #   ssh-keygen -t ed25519 -N "" -f /etc/secrets/initrd/ssh_host_ed25519_key
  # This is a dedicated initrd-only host key, deliberately NOT the main host
  # key — it lives unencrypted (outside the LUKS volume, since initrd runs
  # before unlock) at the path below. See hosts/pegasus/MANUAL-STEPS.md.
  boot.initrd.systemd.enable = true; # required for LUKS SSH unlock

  boot.initrd.network = {
    enable = true;
    ssh = {
      enable = true;
      port = 2222;
      authorizedKeys = [
        "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQCfTHdojQvKOlTaaTYT2RmYMNKQ/6rBQwn6V+bPnrtASaI/G5E7RW67XGbZHi3K7EctyB9UP9Uw54sayEu4ebixI/dNFVVWeZ2byBQ49FoXh5o9Cfok0Qwf0QM7g9Td8O6Iu2ElnI8e+9cr8ThrfPpKmP68e6mpuYDvhQb4omcx8kRhxnsuNxkL2xCTNVxG/jw68o/1KHX++6tRqf0E3PBCjZ3Z8HMTdS8ouEBa8Y96GGeUvslwDJ9cUtLNCUhR5t3mGu3iSS9RYpFg/JujyTT9yhe2O/0og+OhBeSayGZMOXGWngGUEItExlbq2I4rMV5pFB1q+OyqksvlUfkJ/j3yJOii5uwonYvkWLZfR02yhn2b/bgOfYaimO5rfKj5jAC8bMRnWqLJAiG2qRDwtJT+ijyYlTKgLpz73sOGAQVvZygq11Vc35cZMFojlMeqAHdZMGi6XkUHnfZt8gyplw6VPV5EQnyDI4bRfY9sknuFvjHqdEzNyNrIEXtlmIB870s= z@Serenity.local"
      ];
      hostKeys = [ "/etc/secrets/initrd/ssh_host_ed25519_key" ];
    };
  };

  # Onboard NIC (enp42s0) is Realtek, driver confirmed 2026-07-11 via
  # `readlink -f /sys/class/net/enp42s0/device/driver` while booted normally
  # — r8169, not built into the initrd by default (hardware-configuration.nix's
  # generated module list only covers storage). Without this the NIC never
  # comes up pre-unlock, which is exactly what the first LUKS-remote-unlock
  # test hit: initrd SSH just timed out, indistinguishable from the box not
  # being at the prompt yet, until confirmed on-screen that it genuinely was.
  boot.initrd.availableKernelModules = lib.mkAfter [ "r8169" ];

  # Same NetworkManager/initrd-DHCP interaction memory-alpha hit: with
  # networking.networkmanager.enable = true (implicitly networking.useDHCP =
  # false), switch-root leaves the initrd's DHCP-assigned address/routes in
  # place, and NetworkManager then adopts the interface as "connected
  # (externally)" instead of re-negotiating — which is the only thing that
  # populates /etc/resolv.conf. Net effect without this: routing works, DNS is
  # empty, every boot. Flush right before switch-root so NetworkManager always
  # starts clean. Generalized over any ethernet-type interface rather than a
  # hardcoded name (pegasus doesn't rename its NIC via systemd.network.links
  # the way memory-alpha does for its USB dongles).
  boot.initrd.systemd.services.flush-network-before-switch-root = {
    description = "Flush initrd DHCP state so NetworkManager re-negotiates DNS";
    before = [ "initrd-switch-root.target" ];
    wantedBy = [ "initrd-switch-root.target" ];
    unitConfig.DefaultDependencies = false;
    serviceConfig.Type = "oneshot";
    path = [ pkgs.iproute2 pkgs.gawk ];
    script = ''
      for iface in $(ip -o link show type ether | awk -F': ' '{print $2}'); do
        ip addr flush dev "$iface" || true
      done
    '';
  };

  # path = [ pkgs.iproute2 ] only sets $PATH inside the unit — it doesn't get
  # `ip` copied into the initrd image itself. Without this the flush above
  # silently no-ops (`|| true` swallows the "command not found") and every
  # boot inherits stale DHCP state. See memory-alpha's configuration.nix for
  # how this one was actually diagnosed.
  boot.initrd.systemd.storePaths = [ "${pkgs.iproute2}/bin/ip" ];

  # Audible chimes at the two initrd milestones that matter when unlocking
  # headlessly. Both just write BEL (\a) to /dev/console — no ALSA, nothing
  # extra needed in the initrd's minimal closure.
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

  # ── sops-nix ────────────────────────────────────────────────────────────────
  # Uses the host's SSH ed25519 key as the age identity. After first boot:
  #   ssh-to-age < /etc/ssh/ssh_host_ed25519_key.pub
  # then replace the pegasus placeholder in .sops.yaml and run
  #   sops updatekeys secrets/pegasus.yaml
  sops = lib.mkIf hasSops {
    defaultSopsFile = ../../secrets/pegasus.yaml;
    age.sshKeyPaths = [ "/etc/ssh/ssh_host_ed25519_key" ];
    secrets."tailscale/authKey" = { };
    # Declarative login password for z (2026-07-11) — without this, a fresh
    # install leaves the account genuinely passwordless/locked (NixOS doesn't
    # set one unless told to), which is exactly what caused every SDDM login
    # attempt to fail PAM auth on first boot here. SSH still worked throughout
    # since that's key-based, not password-based — see hosts/pegasus/DECISIONS.md.
    secrets."z/hashedPassword".neededForUsers = true;
    # z's outbound SSH key (2026-07-11) — for git/ssh from pegasus itself
    # (GitHub, the other fleet hosts), not to be confused with the host's
    # own SSH key (used as the sops/age identity, above) or the LUKS
    # remote-unlock initrd key (deliberately kept OUTSIDE sops, unencrypted,
    # since initrd runs before secrets are decryptable — see the LUKS SSH
    # unlock section of this file). sops-nix decrypts straight to the target
    # path, creating parent dirs as needed — no home-manager wiring required.
    secrets."ssh/z_ed25519" = {
      owner = "z";
      group = "users";
      mode = "0400";
      path = "/home/z/.ssh/id_ed25519";
    };
  };

  users.users.z.hashedPasswordFile =
    lib.mkIf hasSops config.sops.secrets."z/hashedPassword".path;

  # Elgato Stream Deck — udev rule for non-root /dev/hidraw access. The
  # streamdeck-ui package (installed via home.packages in home.nix) ships
  # this rule but doesn't wire it in automatically; needs registering here.
  services.udev.packages = [ pkgs.streamdeck-ui ];

  # @games (see hardware-configuration.nix / disko.nix) is a freshly created
  # BTRFS subvolume root — owned by root:root with 0755 perms by default,
  # like any subvolume root, since nothing at mkfs/install time set it
  # otherwise. Steam runs as z and couldn't create a library there at all
  # until this is fixed. Declarative rather than a one-off `chown` so it
  # survives a reinstall without a manual step.
  systemd.tmpfiles.rules = [ "d /games 0755 z users - -" ];

  # ── home-manager ──────────────────────────────────────────────────────────
  home-manager = {
    useGlobalPkgs = true;
    useUserPackages = true;
    users.z = import ./home.nix;
  };

  # Internet-facing? No — LAN/tailnet only. Traefik/LE machinery lives on
  # memory-alpha; pegasus does not import it.
  system.stateVersion = "26.05";
}
