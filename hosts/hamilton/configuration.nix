{ config, pkgs, lib, ... }:

{
  imports = [
    ../../modules/nixos/common.nix
    ../../modules/nixos/dns.nix
  ];

  networking.hostName = "hamilton";  # placeholder — rename when the unit is in hand
  # DHCP reservation on the GL.iNet router is the source of truth for the IP.
  # Add this host's IP as the *secondary* DNS server in the router's DHCP
  # settings — that's the whole failover story (primary = hopper).
  networking.networkmanager.enable = true;

  # ── Raspberry Pi 3 ──────────────────────────────────────────────────────────
  # Boot/hardware come from nixos-hardware's raspberry-pi-3 profile + nixpkgs'
  # sd-image-aarch64 module (wired up in flake.nix). The Pi 3 boots from SD —
  # USB boot is unreliable on this board, so don't rely on it. As a backup
  # resolver this host rebuilds rarely, so SD wear isn't a real concern.

  # ── sops-nix ──────────────────────────────────────────────────────────────
  # After first boot:  ssh-to-age < /etc/ssh/ssh_host_ed25519_key.pub
  # then put that pubkey in .sops.yaml (replacing the hamilton placeholder) and
  #   sops updatekeys secrets/hamilton.yaml
  sops = {
    defaultSopsFile = ../../secrets/hamilton.yaml;
    age.sshKeyPaths = [ "/etc/ssh/ssh_host_ed25519_key" ];
  };

  # ── Tailscale (plain client) ────────────────────────────────────────────────
  # Not an exit node — just tailnet membership so the box (and its AdGuard UI)
  # is reachable remotely. Reuses the same authKey secret convention as hopper.
  sops.secrets."tailscale/authKey" = {};
  services.tailscale = {
    enable = true;
    authKeyFile = config.sops.secrets."tailscale/authKey".path;
  };
  networking.firewall.trustedInterfaces = [ "tailscale0" ];
  networking.firewall.allowedUDPPorts = [ config.services.tailscale.port ];

  # Note: dns.nix binds the AdGuard web UI to localhost (it expects Traefik on
  # hopper). There's no Traefik here, so reach this box's UI over the tailnet
  # via an SSH tunnel, or set services.adguardhome.host to the tailnet IP if
  # you want it bound directly. DNS itself serves on :53 to the LAN regardless.

  # ── home-manager ──────────────────────────────────────────────────────────
  home-manager = {
    useGlobalPkgs = true;
    useUserPackages = true;
    users.z = import ./home.nix;
  };

  system.stateVersion = "26.05";
}
