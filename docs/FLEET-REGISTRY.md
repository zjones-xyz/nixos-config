# Fleet registry — design and roadmap

The fleet registry (`fleet/`, exposed as `homelab.fleet.*` by
`modules/nixos/fleet.nix`) records each fixed LAN address and each single-host
service once, and generates configuration from it. This file is where the
plan for it lives: what's done, what's next, and what's still undecided.
`CLAUDE.md` has the short version of how to use it.

## Why it exists

DNS rewrites live in galactica's closure, but the services they point at live
on other hosts. Before the registry, nothing connected the two except memory:
moving or adding a service meant remembering to edit galactica's hand-written
rewrite list, and the same IPs were typed out in several places.

## Shape

- **`fleet/hosts.nix`**: name → IP for the fixed LAN addresses that need a
  name or an AdGuard client label. That covers NixOS hosts, but also the
  router, the BMC and containers such as `bambuddy`. Not every fixed address is
  here (Bambuddy's virtual-printer addresses .95-.97 aren't), and adding one
  makes it an AdGuard client. Entries are labelled in AdGuard ordered by IP.
- **`fleet/services.nix`**: one entry per single-host service: the machine
  that serves it, a `scope`, and the DNS planes it answers on.
- **`fleet/lib.nix`**: pure functions that turn those into AdGuard rewrite rows
  and assertions.
- **Planes**:
  - `internal`: a `.internal` name, self-signed cert, answers with a LAN
    address.
  - `private`: a `zjones.dev` name with a Let's Encrypt cert, answering with a
    LAN address. The cert is browser-trusted once the serving host sets
    `homelab.letsencryptStaging = false` (the default is staging). These names
    are meant to resolve only through AdGuard, which is why their certs use
    DNS-01.
  - `public`: a `zjones.xyz` name reachable from the internet through
    Pangolin. On the LAN it only gets a split-horizon rewrite, which
    `homelab.dns.splitHorizon` can drop fleet-wide (kept so the tunnel path
    can be tested).
- **Scope**: `flat` gives `name.internal` and so on; `host` gives
  `name.<host>.internal`. Every service today is `flat`.

## Phase 1 — generated DNS rewrites (#107, #232)

Done once both merge:

- Single-host flat-name services declare their names in `services.nix`;
  galactica generates their AdGuard rewrites and appends them to its own
  hand-written list. Generation stays on galactica because it's the rewrite
  origin and the Pis receive rewrites only by sync (`hosts/hopper/DECISIONS.md`
  §5).
- AdGuard's client list is built from `hosts.nix`, ordered by IP.
- Assertions fail every host's eval on an unknown `host`, two services claiming
  one name, or a generated rewrite duplicating a hand-written one. That check is
  exact-name only: a wildcard overlapping a generated name isn't flagged, and
  needn't be, because AdGuard answers with the exact rewrite over the wildcard.

Traefik stays hand-written in Phase 1.

## Later phases

### Traefik generation (Phases 2-3 in the original design)

Generate each service's Traefik routers from the same `services.nix` entry that
generates its DNS rows, so a name can't be resolvable but unrouted, or routed
but unresolvable.

- Host fields for each machine's Traefik shape return here: which names it
  holds a wildcard or anchor cert for, and whether its Traefik is the compose
  or native module. Phase 1 dropped them because nothing read them and they
  had already drifted.
- `jellyfin.internal` gets turned on here. It's `planes.internal = false` today
  because memory-alpha has no `.internal` router for it.
- A `public` name that LAN clients reach through the split-horizon rewrite
  needs a local router too; memory-alpha's `jellyfin-xyz` is the pattern.
  `guest.zjones.xyz` gets one by hand first (#124 step 6a).

### Registry coverage (not yet scheduled)

- **Wildcard groups.** Add a scope that can express `*.maker`, `read.*` and
  `*.3dp`. These are hand-written in galactica's `configuration.nix` today.
- **Host identities from `hosts.nix`.** Generate `hopper.internal`,
  `hamilton.internal` and the `galactica`/`tower`/`arr` names from the
  registry, so an IP lives in one place. Until then they're hand-written, and
  nothing checks that their IPs match `hosts.nix`.
- **A CI no-op guard.** A flake `checks` output asserting galactica's rewrite
  set, replacing the before/after comparisons each registry change has proved
  by hand.

## Open decisions

1. [ ] **How Traefik generation divides between Phase 2 and Phase 3.** The
   original design called it "Phases 2-3" without saying where the split
   falls, and placed `jellyfin.internal` in Phase 3.
2. [ ] **Where the registry-coverage items go:** before Traefik generation,
   alongside it, or after.
3. [ ] **Whether `memory-alpha-2.internal` retires.** .98 is Bambuddy's address
   and is labelled `bambuddy` in AdGuard, but the legacy DNS names are kept
   because a printer or slicer may still use them.
