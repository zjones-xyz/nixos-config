{ config, pkgs, lib, ... }:

# ─────────────────────────────────────────────────────────────────────────────
# Beszel agent (native), reporting to the hub on hopper
# ─────────────────────────────────────────────────────────────────────────────
# Deliberately NOT modules/nixos/beszel.nix: that module is the hopper *hub*,
# and it predates nixpkgs having anything native — it runs hub and agent as
# Docker containers behind Traefik. nixpkgs now ships `services.beszel.agent`,
# so an agent-only host has no reason to pull in Docker, a compose file, or a
# container image tag that drifts. Same telemetry, one systemd unit.
#
# GPU metrics come for free: the upstream module puts nvidia-smi on the
# agent's PATH when services.xserver.videoDrivers contains "nvidia", which it
# does here (modules/nixos/nvidia.nix) — no extra wiring, no extraPath entry.
let
  # sops-nix fails *activation* when a declared secret is missing from the
  # encrypted file, so declaring beszel/agentKey before it exists would break
  # the next `nixos-rebuild switch` rather than just leaving the agent idle.
  # sops encrypts values but not key names, so the presence of the key is
  # readable straight out of the committed ciphertext — gate on that. Adding
  # the secret is then the only action needed to turn this on; until then the
  # host builds and switches exactly as before.
  #
  # Same spirit as the `hasSops` gate in hosts/pegasus/configuration.nix, one
  # level finer: that one asks "is there a secrets file at all", this asks "is
  # this particular secret in it yet".
  sopsFile = config.sops.defaultSopsFile;
  hasAgentKey =
    sopsFile != null
    && builtins.pathExists sopsFile
    && lib.hasInfix "\nbeszel:" (builtins.readFile sopsFile);
in
{
  sops.secrets."beszel/agentKey" = lib.mkIf hasAgentKey { };

  services.beszel.agent = {
    enable = hasAgentKey;

    # KEY=ssh-ed25519 ... — the hub's public key, in EnvironmentFile format.
    # Exactly the same secret shape hopper's containerised agent consumes via
    # compose `env_file`, so the value can be copied between hosts' sops files
    # verbatim.
    environmentFile = lib.mkIf hasAgentKey config.sops.secrets."beszel/agentKey".path;

    # No openFirewall. The hub dials the agent (hub → agent:45876), not the
    # other way round, and pegasus already treats tailscale0 as a trusted
    # interface — so adding the system in the hub by its *tailnet* address
    # works with no LAN-facing port. Opening 45876 outright, the way the
    # hopper module does, would expose it to the whole LAN for no gain.
    openFirewall = false;
  };
}
