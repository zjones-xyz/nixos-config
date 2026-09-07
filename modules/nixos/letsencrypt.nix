{ config, lib, ... }:

{
  # Shared switch for the Let's Encrypt CA used by the Traefik modules
  # (traefik.nix, traefik-local.nix, traefik-hamilton.nix, traefik-galactica.nix).
  #
  # The CA half of the staging/production switch lives here as a derived
  # option; only the storage path is per-host. traefik-galactica.nix consumes
  # it; ⟨follow-up: the three older Traefik modules still carry their own copy
  # of the ternary, plus the shared ACME email, resolver pair and
  # `docker-proxy-network` oneshot — collapse those when unifying them.⟩
  options.homelab.letsencryptStaging = lib.mkOption {
    type = lib.types.bool;
    default = true;
    description = ''
      Use the Let's Encrypt staging CA instead of production.

      Staging issues from an untrusted root (browsers warn) but has very high
      rate limits, so it's safe for debugging cert issuance. Production has
      strict limits — notably 5 duplicate certs per week — that are easy to
      exhaust while iterating across hosts.

      Staging and production certs are stored in separate acme.json files, so
      flipping this flag never requires deleting cached certs by hand.

      Defaults to true (staging). Set to false per-host once issuance is
      verified, or once in common.nix to flip every host to production.
    '';
  };

  options.homelab.letsencryptCaServer = lib.mkOption {
    type = lib.types.str;
    readOnly = true;
    default =
      if config.homelab.letsencryptStaging
      then "https://acme-staging-v02.api.letsencrypt.org/directory"
      else "https://acme-v02.api.letsencrypt.org/directory";
    defaultText = lib.literalExpression "the CA matching homelab.letsencryptStaging";
    description = "ACME caServer URL derived from `homelab.letsencryptStaging`.";
  };
}
