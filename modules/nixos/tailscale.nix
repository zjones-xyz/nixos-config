{ config, pkgs, lib, ... }:

{
  # Tailscale — hopper acts as an exit node for the tailnet.
  #
  # The auth key is provisioned via sops so the node can come up headless.
  # Generate a reusable/ephemeral auth key in the Tailscale admin console and
  # store it under `tailscale/authKey` in secrets/hopper.yaml.
  #
  # After it's up, approve the exit node in the admin console (Machines →
  # hopper → Edit route settings → Use as exit node).

  sops.secrets."tailscale/authKey" = {};

  services.tailscale = {
    enable = true;
    # "server" enables IP forwarding + optimisations needed to route traffic
    # for other nodes (exit node / subnet router).
    useRoutingFeatures = "server";
    authKeyFile = config.sops.secrets."tailscale/authKey".path;
    extraUpFlags = [
      "--advertise-exit-node"
      "--ssh"
    ];
  };

  # Exit-node forwarding. useRoutingFeatures = "server" sets these too, but we
  # pin them explicitly so the intent is obvious and survives refactors.
  boot.kernel.sysctl = {
    "net.ipv4.ip_forward" = 1;
    "net.ipv6.conf.all.forwarding" = 1;
  };

  # Trust the tailnet interface; tailscaled's UDP port must be reachable.
  networking.firewall = {
    trustedInterfaces = [ "tailscale0" ];
    allowedUDPPorts = [ config.services.tailscale.port ];
  };
}
