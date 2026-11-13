{ config, lib, ... }:

# ── User-defined Docker networks, recreated on every start ─────────────────
# autoPrune (common.nix) deletes any network with no container attached at that
# moment. A once-per-boot oneshot stays "active" and never recreates it, so each
# consumer ensures the network in its own preStart instead. `create || inspect`
# tolerates two consumers starting at once.
let
  docker = "${config.virtualisation.docker.package}/bin/docker";
  ensure = name: net: ''
    ${docker} network create ${lib.escapeShellArgs net.createOptions} ${name} >/dev/null 2>&1 \
      || ${docker} network inspect ${name} >/dev/null
  '';
in
{
  options.homelab.dockerNetworks = lib.mkOption {
    type = lib.types.attrsOf (lib.types.submodule {
      options = {
        services = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = [ ];
          description = "systemd services (no `.service` suffix) that join this network; each recreates it before starting.";
        };
        createOptions = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = [ ];
          description = "Extra `docker network create` flags.";
        };
      };
    });
    default = { };
    description = "Docker networks, keyed by name, created on demand by the services that use them.";
  };

  config.systemd.services = lib.mkMerge (lib.mapAttrsToList
    (name: net: lib.genAttrs net.services (_: { preStart = lib.mkBefore (ensure name net); }))
    config.homelab.dockerNetworks);
}
