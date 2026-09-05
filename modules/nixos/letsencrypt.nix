{ lib, ... }:

{
  # Shared switch for the Let's Encrypt CA used by the Traefik modules
  # (traefik.nix, traefik-local.nix, traefik-hamilton.nix, traefik-galactica.nix).
  #
  # ⟨Follow-up: the CA/storage ternary this flag drives is copy-pasted into all
  # four of those modules.⟩ Only the storage path differs per host, so the CA
  # half could live here as a read-only derived option and the four `let`
  # blocks would collapse. Worth doing as part of unifying those modules rather
  # than on its own — they also share the ACME account email, the Cloudflare
  # DNS-01 resolver pair, and a verbatim `docker-proxy-network` oneshot.
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
}
