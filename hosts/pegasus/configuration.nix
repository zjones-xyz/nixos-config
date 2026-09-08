{ config, pkgs, lib, ... }:

{
  imports = [
    ./hardware-configuration.nix
    ./borgmatic.nix
    ../../modules/nixos/common.nix
    ../../modules/nixos/nvidia.nix
    ../../modules/nixos/desktop-plasma.nix
    ../../modules/nixos/desktop-cosmic.nix
    ../../modules/nixos/desktop-dragonized.nix
    ../../modules/nixos/desktop-niri.nix
    ../../modules/nixos/dankcalendar.nix
    ../../modules/nixos/scrutiny-collector.nix
    # Settles which of the two Secret Service providers the desktop modules
    # above each drag in silently is the one that actually runs.
    ../../modules/nixos/keyring.nix
    ../../modules/nixos/gaming.nix
    ../../modules/nixos/performance.nix
    ../../modules/nixos/btrfs-snapshots.nix
    ../../modules/nixos/ollama.nix
    ../../modules/nixos/yubikey.nix
    ../../modules/nixos/nzxt-kraken.nix
    ../../modules/nixos/keyboards.nix
    ../../modules/nixos/mouse-tools.nix
    ../../modules/nixos/luks-remote-unlock.nix
    # olla-router.nix is deliberately parked: its build runs olla's own Go
    # test suite, which has a wall-clock assertion that fails under the Nix
    # sandbox. ollama.nix works standalone. Re-enable steps: MANUAL-STEPS §5.
    # ../../modules/nixos/olla-router.nix
  ];

  networking.hostName = "pegasus";
  networking.networkmanager.enable = true;

  # pegasus is where Tower's cards get flashed and probed, which is all lspci
  # work (hosts/galactica/PLATFORM.md §6). environment.systemPackages rather
  # than home.packages so `sudo lspci` resolves — sudo does not inherit the
  # user profile's PATH.
  environment.systemPackages = with pkgs; [
    pciutils
    nmap
  ];

  # ── DDC/CI (ddcutil) ─────────────────────────────────────────────────────────
  # ddcutil itself is installed via home.packages (home.nix) — this is just the
  # kernel/udev wiring it needs: loads i2c-dev and grants read/write on
  # /dev/i2c-* to whoever's logged in at the seat (and to members of a new
  # "i2c" group), so no sudo/group-membership dance is needed to run it. See
  # modules/nixos/nvidia.nix for the other half — the driver-side I2C fix
  # this proprietary-NVIDIA host also needs for ddcutil to actually work.
  hardware.i2c.enable = true;

  # ── Boot ────────────────────────────────────────────────────────────────────
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  # Stock mainline kernel (NOT a CachyOS/Chaotic kernel), pinned to 7.1: the
  # NVIDIA production driver (open and proprietary alike) doesn't build
  # against 7.2's kernel-interface changes — see hosts/pegasus/DECISIONS.md.
  # Bump back to `linuxPackages_latest` once nixpkgs/NVIDIA ship a 7.2 fix.
  boot.kernelPackages = pkgs.linuxPackages_7_1;

  # Fleet default (modules/nixos/common.nix) reboots 10s after a panic. Pegasus
  # has a physical display attached, so widen that to 600s — enough time to
  # walk over and read/photograph the panic screen before it auto-reboots and
  # the evidence is gone.
  boot.kernel.sysctl."kernel.panic" = 600;

  # ── Tailscale ───────────────────────────────────────────────────────────────
  # Pegasus is reached over the tailnet (it is the primary GPU inference
  # endpoint — see modules/nixos/ollama.nix). It is NOT an exit node, so we
  # do not reuse the hopper-flavoured modules/nixos/tailscale.nix here.
  services.tailscale = {
    enable = true;
    extraUpFlags = [ "--ssh" ];
    authKeyFile = config.sops.secrets."tailscale/authKey".path;
  };
  networking.firewall.trustedInterfaces = [ "tailscale0" ];
  networking.firewall.allowedUDPPorts = [
    config.services.tailscale.port

    # Bambu Lab printer LAN-mode auto-discovery: the printer periodically
    # broadcasts its presence over UDP (source port 1900), and Bambu
    # Studio/OrcaSlicer just listen for it on 2021 — nothing sends a query
    # first, so the default stateful firewall drops it as unsolicited
    # inbound unless the port is opened. 1900 is also opened since some
    # printer firmware/slicer combos use it directly rather than just as
    # the broadcast's source port. Requires the printer to actually be on
    # the same L2 broadcast domain as this host (crosses a LAN<->WLAN
    # bridge fine if the AP bridges them into one domain; doesn't cross a
    # router/VLAN boundary without a relay).
    2021
    1900
  ];

  # ── Remote Desktop (xrdp) ────────────────────────────────────────────────────
  # Supersedes KRDP, which can only mirror an already-logged-in session — see
  # DECISIONS.md. xrdp/xorgxrdp spins up an independent Plasma-X11 session per
  # connection, so it works whether the console is at the greeter, locked, or
  # logged out. Deliberately no `openFirewall`: tailscale0 is already a
  # trusted interface, and the module has no per-interface bind option, so the
  # tailnet-only boundary is enforced at the firewall. Auth is PAM against
  # z's account password (the sops z/hashedPassword below) — nothing extra.
  services.xrdp = {
    enable = true;
    defaultWindowManager = "${pkgs.kdePackages.plasma-workspace}/bin/startplasma-x11";
  };

  # ── LUKS SSH unlock ─────────────────────────────────────────────────────────
  # The shared flow lives in modules/nixos/luks-remote-unlock.nix (imported
  # above); only pegasus's host-specific piece stays here — the onboard
  # Realtek NIC's driver, which the generated initrd module list (storage
  # only) omits. Without it the NIC never comes up pre-unlock and initrd SSH
  # just times out.
  boot.initrd.availableKernelModules = lib.mkAfter [ "r8169" ];

  # ── sops-nix ────────────────────────────────────────────────────────────────
  # Uses the host's SSH ed25519 key as the age identity. After first boot:
  #   ssh-to-age < /etc/ssh/ssh_host_ed25519_key.pub
  # then replace the pegasus placeholder in .sops.yaml and run
  #   sops updatekeys secrets/pegasus.yaml
  sops = {
    defaultSopsFile = ../../secrets/pegasus.yaml;
    age.sshKeyPaths = [ "/etc/ssh/ssh_host_ed25519_key" ];
    secrets."tailscale/authKey" = { };
    # Declarative login password for z — without this, a fresh install leaves
    # the account genuinely passwordless/locked (NixOS doesn't set one unless
    # told to), failing every SDDM/PAM login while key-based SSH still works.
    secrets."z/hashedPassword".neededForUsers = true;
    # z's outbound SSH key — for git/ssh from pegasus itself
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

  users.users.z.hashedPasswordFile = config.sops.secrets."z/hashedPassword".path;

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

  # ── 1Password ────────────────────────────────────────────────────────────────
  # NixOS modules, not plain home.packages entries (which is how the GUI+CLI
  # pair were installed before). The plain-package form is enough to run
  # `1password` and `op` standalone, but the desktop app's Settings → Developer
  # → "Integrate with 1Password CLI" toggle only authorizes a CLI binary that's
  # setgid-wrapped into the `onepassword-cli` group — these modules are what
  # actually create that wrapper (security.wrappers."op" /
  # security.wrappers."1Password-BrowserSupport"), per nixpkgs'
  # nixos/modules/programs/_1password{,-gui}.nix. Without them the toggle has
  # nothing to authorize and biometric/session-based `op read op://...` (used
  # by the ipmi-tower-* aliases in home.nix) never actually unlocks.
  # polkitPolicyOwners grants the wrapper to z, the only account on this box.
  programs._1password.enable = true;
  programs._1password-gui = {
    enable = true;
    polkitPolicyOwners = [ "z" ];
  };

  # ── home-manager ──────────────────────────────────────────────────────────
  home-manager = {
    useGlobalPkgs = true;
    useUserPackages = true;
    users.z = import ./home.nix;
  };

  # Four real disks — three SATA plus the NVMe root — so smartd has plenty to
  # poll (modules/nixos/smart.nix; inventory in HARDWARE-MAP.md §1).
  # ⚠ smartd will autodetect the NanoKVM's emulated mass-storage device too and
  # find nothing to report on it. Harmless, but do not read its silence as a
  # disk being healthy — it is not a disk.
  homelab.smart.monitor = true;

  # Same disks, reported to the Scrutiny hub on memory-alpha for trend history
  # alongside smartd's local alerting.
  services.scrutinyCollector.enable = true;

  # Internet-facing? No — LAN/tailnet only. Traefik/LE machinery lives on
  # memory-alpha; pegasus does not import it.
  system.stateVersion = "26.05";
}
