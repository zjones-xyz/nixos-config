{ config, pkgs, lib, ... }:

let
  fleetLib = import ../../fleet/lib.nix { inherit lib; };
  inherit (lib) mkOption types;

  bool = default: mkOption {
    type = types.bool;
    inherit default;
  };

  plane = default: description: mkOption {
    type = types.bool;
    inherit default description;
  };
in
{
  # ── Fleet registry: typed, read-only views of fleet/{hosts,services}.nix ───
  # Imported from common.nix so every host evaluates the assertions below —
  # a bad registry fails CI's per-host eval, not just galactica's. Edit the
  # data files, not these options.
  options.homelab.fleet = {
    hosts = mkOption {
      readOnly = true;
      description = "Fleet hosts (fleet/hosts.nix).";
      type = types.attrsOf (types.submodule {
        options.ip = mkOption { type = types.str; };
      });
    };

    services = mkOption {
      readOnly = true;
      description = "Singleton services and the DNS planes they answer on (fleet/services.nix).";
      type = types.attrsOf (types.submodule {
        options = {
          host = mkOption { type = types.str; };
          scope = mkOption {
            type = types.enum [ "flat" "host" ];
            default = "host";
          };
          # internal and private both answer with a LAN address; the
          # certificate is what tells them apart. public is the internet name.
          planes = {
            internal = plane true "A `.internal` name with a self-signed cert. Answers with a LAN address.";
            private = plane true "A `zjones.dev` name with a trusted Let's Encrypt cert. Answers with a LAN address; never resolves publicly.";
            public = plane false "A `zjones.xyz` name, reachable from the internet through Pangolin. On the LAN it gets a split-horizon rewrite, which `splitHorizon` can drop.";
          };
          splitHorizon = bool true;
          note = mkOption {
            type = types.str;
            default = "";
          };
        };
      });
    };
  };

  # Drops every generated public (`.xyz`) row (not enabled = false — AdGuardHome-Sync
  # mirroring of that isn't trusted). Fleet-wide and redeploys galactica: for
  # one-off debugging use `dig @1.1.1.1` or `curl --resolve` instead.
  options.homelab.dns.splitHorizon = bool true;

  config = {
    homelab.fleet.hosts = import ../../fleet/hosts.nix;
    homelab.fleet.services = import ../../fleet/services.nix;

    assertions =
      fleetLib.hostAssertions { inherit (config.homelab.fleet) hosts services; }
      ++ fleetLib.uniqueDomainAssertions { inherit (config.homelab.fleet) services; }
      ++ fleetLib.mergedRewriteAssertions (config.services.adguardhome.settings.filtering.rewrites or [ ]);
  };
}
