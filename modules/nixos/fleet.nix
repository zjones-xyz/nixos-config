{ config, lib, ... }:

let
  fleetLib = import ../../fleet/lib.nix { inherit lib; };
in
{
  # ── Fleet registry — read-only options over fleet/hosts.nix + fleet/services.nix ─
  # Singleton services declare their DNS names once here instead of only in
  # galactica's AdGuard rewrite list (dns.nix generates rewrites from this).
  # Read-only: the registry is edited by changing the data files, not by
  # setting these from a host's configuration.nix.

  options.homelab.fleet.hosts = lib.mkOption {
    type = lib.types.attrsOf (
      lib.types.submodule {
        options = {
          ip = lib.mkOption {
            type = lib.types.str;
            description = "LAN IPv4 address.";
          };
          certAnchors = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            default = [ ];
            description = "Domain(s) this host's Traefik module requests a wildcard/anchor cert for. Informational only in this phase.";
          };
          traefik = lib.mkOption {
            type = lib.types.nullOr (lib.types.enum [ "compose" "native" ]);
            default = null;
            description = "This host's Traefik deployment shape. Informational only in this phase — Traefik generation is a future phase.";
          };
        };
      }
    );
    readOnly = true;
    description = "Fleet-wide host registry, sourced from fleet/hosts.nix.";
  };

  options.homelab.fleet.services = lib.mkOption {
    type = lib.types.attrsOf (
      lib.types.submodule {
        options = {
          host = lib.mkOption {
            type = lib.types.str;
            description = "Key of homelab.fleet.hosts this service runs on.";
          };
          scope = lib.mkOption {
            type = lib.types.enum [ "flat" "host" ];
            default = "host";
            description = ''
              "flat": name.internal / name.zjones.dev / name.zjones.xyz.
              "host": name.host.internal / name.host.zjones.dev / name.host.zjones.xyz.
            '';
          };
          planes = lib.mkOption {
            type = lib.types.submodule {
              options = {
                internal = lib.mkOption {
                  type = lib.types.bool;
                  default = true;
                  description = "Self-signed, routed by Traefik.";
                };
                dev = lib.mkOption {
                  type = lib.types.bool;
                  default = true;
                  description = "Let's Encrypt, routed by Traefik.";
                };
                xyz = lib.mkOption {
                  type = lib.types.bool;
                  default = false;
                  description = "Pangolin/Newt tunnel — split-horizon rewrite only, never a router.";
                };
              };
            };
            default = { };
            description = "Which DNS planes this service answers on.";
          };
          splitHorizon = lib.mkOption {
            type = lib.types.bool;
            default = true;
            description = "Whether the .xyz LAN rewrite row is emitted for this service, ANDed with the fleet-wide homelab.dns.splitHorizon switch.";
          };
          note = lib.mkOption {
            type = lib.types.str;
            default = "";
            description = "Free text. Not consumed by any generator.";
          };
        };
      }
    );
    readOnly = true;
    description = "Fleet-wide singleton-service registry, sourced from fleet/services.nix.";
  };

  # For one-off ingress debugging (checking whether a single name resolves,
  # or bypassing a rewrite for one test), prefer `dig @1.1.1.1 <name>`,
  # `curl --resolve`, or a per-device DNS override — NOT this flag. Flipping
  # it redeploys galactica (dns.nix's rewrites are declarative) and moves the
  # WHOLE LAN's .xyz resolution onto the external Pangolin path at once.
  options.homelab.dns.splitHorizon = lib.mkOption {
    type = lib.types.bool;
    default = true;
    description = ''
      Fleet-wide kill switch for every generated `.xyz` DNS rewrite row
      (fleet/lib.nix's `rewritesFor`). Set false to make LAN clients resolve
      `.xyz` names through the real, external Pangolin path instead of the
      split-horizon shortcut — e.g. to test the tunnel itself.

      Per-service `splitHorizon` in fleet/services.nix is ANDed with this;
      either one off drops that service's `.xyz` row.
    '';
  };

  config = {
    homelab.fleet.hosts = import ../../fleet/hosts.nix;
    homelab.fleet.services = import ../../fleet/services.nix;

    assertions =
      (fleetLib.hostAssertions {
        hosts = config.homelab.fleet.hosts;
        services = config.homelab.fleet.services;
      })
      ++ (fleetLib.uniqueDomainAssertions { services = config.homelab.fleet.services; });
  };
}
