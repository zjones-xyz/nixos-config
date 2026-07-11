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
    ../../modules/nixos/gaming.nix
    ../../modules/nixos/performance.nix
    ../../modules/nixos/ollama.nix
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

  # ── Boot ────────────────────────────────────────────────────────────────────
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  # Stock latest mainline kernel (NOT a CachyOS/Chaotic kernel). sched-ext is
  # upstream since 6.12, so the stock kernel is all scx needs — see
  # modules/nixos/performance.nix. If the NVIDIA production driver ever lags the
  # bleeding-edge kernel, drop this line to fall back to the default kernel
  # (still >= 6.12). See hosts/pegasus/DECISIONS.md.
  boot.kernelPackages = pkgs.linuxPackages_latest;

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

  # ── sops-nix ────────────────────────────────────────────────────────────────
  # Uses the host's SSH ed25519 key as the age identity. After first boot:
  #   ssh-to-age < /etc/ssh/ssh_host_ed25519_key.pub
  # then replace the pegasus placeholder in .sops.yaml and run
  #   sops updatekeys secrets/pegasus.yaml
  sops = lib.mkIf hasSops {
    defaultSopsFile = ../../secrets/pegasus.yaml;
    age.sshKeyPaths = [ "/etc/ssh/ssh_host_ed25519_key" ];
    secrets."tailscale/authKey" = { };
  };

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
