# galactica — the reading stack

The books/comics/audiobooks half of galactica, complementing the *arr media
stack (`nixflix.nix`, `MANUAL-STEPS.md` §12). Companion to `SHARES.md` (which
shares this inherits and their tiers) and `DECISIONS.md` (why, for anything here
that looks arbitrary).

**Status: spec in progress.** Settled 2026-09-15: the *client* half — what serves
and what reads (§1–§4) — the *acquisition* half (§5), and the storage layout
(§6), and exposure, names and auth (§7). What remains is secrets and the
borgmatic hook; see "Still open" at the end. **Nothing is implemented yet:** no
`reading.nix`, no secrets, no Traefik routers, no datasets.

⚠ **Seven units for one subsystem** — Grimmory, MariaDB, Audiobookshelf,
BookBridge, Chaptarr, Shelfmark, Suwayomi — plus reuse of Prowlarr, FlareSolverr,
qBittorrent and SABnzbd from the *arr stack. That is the deliberate price of
covering four content types with two overlapping libraries; §3 and §5 name the
two pieces to drop first if it proves more than it is worth.

---

## 1. Scope

All four content types are in: **ebooks, comics/manga, audiobooks, podcasts.**

| Service | Owns | Shape | In nixpkgs? |
|---|---|---|---|
| **Grimmory** | ebooks, comics/manga, audiobook files | OCI container + **MariaDB** | ❌ container only |
| **Audiobookshelf** | audiobooks, podcasts | `services.audiobookshelf` | ✅ native module |
| **BookBridge** | read/listen progress sync between the two | OCI container + own DB | ❌ container only |
| **Chaptarr** | acquisition: monitoring ebooks + audiobooks | OCI container + SQLite | ❌ container only |
| **Shelfmark** | acquisition: on-demand search across many sources | OCI container (**Lite**) | ❌ container only |
| **Suwayomi** | acquisition: manga | `services.suwayomi-server` | ✅ native module |

**Reading happens in a desktop browser and in phone/tablet apps** — owner-confirmed
2026-09-15. This is a selection *criterion*, not trivia: it is why Calibre-Web's
send-to-Kindle and Kobo-sync endpoints carry no weight here, and why a future
reader should not reopen the app choice on those grounds. There is no Kindle and
no Kobo in the picture.

**Comics/manga is new appetite, not a migration.** None of the 34 Unraid shares
was a comics or manga store (`SHARES.md` §5) — so unlike ebooks and podcasts,
there is no data waiting for it and nothing to import.

### What this inherits from Unraid

| Share | Tier | Becomes |
|---|---|---|
| `books` | 🛡 Protected | Grimmory's library |
| `podcasts_audiobookshelf` | ✅ Re-acquirable | Audiobookshelf's podcasts |
| `books_old` | ⚠ suspected drop | "top level store for BookLore" — resolve *with* the other two |
| `calibre_books` | ⏸ 🛡 Protected (parked) | "probably junk — but"; `SHARES.md` §5 |

⚠ `books` is **Protected** and Grimmory writes under its own library root. Same
trap as `music`/Lidarr (`nixflix.nix`): **import copy-not-move.**

---

## 2. Why these three clients

### Grimmory — because BookLore is gone

BookLore served `books` on Unraid and was **removed from GitHub without notice**;
the community forked it as Grimmory, which auto-migrates BookLore's MariaDB data.
Verified against the canonical repo, 2026-09-15:

- **Formats:** EPUB, MOBI, AZW, AZW3, FB2, PDF, CBZ, CBR, CB7, M4B, M4A, MP3, OPUS.
- **Deployment: containers only** — Docker/Compose images, Helm, Podman Quadlet.
  No JAR, no native build, so there is no native-module path even in principle.
- **Database: MariaDB, mandatory** (`jdbc:mariadb://…:3306/grimmory`, 11.4.5 in
  upstream examples). Postgres and SQLite are not offered.
- **Volumes:** `/app/data` (state), `/books` (library), `/bookdrop` (watched
  import dir). `DISK_TYPE=NETWORK` for NFS/SMB-backed libraries.
- **Auth:** local accounts or OIDC. Multi-user, per-user shelves.
- **Tags:** `vX.Y.Z` stable, `latest` from `main`, `nightly` from `develop`.
- amd64 only (fine — galactica is a Xeon E3-1230 v2).

⚠ **The BookLore auto-migration is a community claim, not a canonical-README
claim.** It appears in the packaging wrapper's README and in community writeups;
the canonical repo's own docs do not document a migration path. Treat it as
plausible-and-testable, not as a guarantee, and see §4.4.

### Audiobookshelf — because Grimmory has no podcasts

Grimmory plays audiobook *files*; it has **no RSS/subscription support**, so
podcasts need Audiobookshelf regardless. It is also the prior art
(`podcasts_audiobookshelf`) and has a native module in the pinned nixpkgs.

### BookBridge — because the audiobook overlap is deliberate (§3)

`cporcellijr/bookbridge`, itself a **fork of `J-Lich/abs-kosync-bridge`** and the
actively-maintained one (~479 stars). Syncs progress across Audiobookshelf,
KOReader, Storyteller, **Grimmory**, BookOrbit, Kavita and Calibre-Web Automated.
Docker-only; services are configured in its web UI rather than by env var; ships
alembic migrations, so it carries its own database.

### Considered and not chosen

⟨**Kavita** and **Komga** both have native NixOS modules and would have avoided a
container, and Kavita would have collapsed ebooks+comics into one service. They
lose to Grimmory on one decisive point: Grimmory is the continuation of the
library that already exists, with the metadata and shelves already in it. Komga
remains the obvious escape hatch if Grimmory's comic reader disappoints — that
was explicitly left as revisitable, and it is additive rather than a rebuild.⟩

⟨**Calibre-Web** loses because its differentiators are Kindle/Kobo delivery,
which this household does not use (§1).⟩

### Sources

- Grimmory (canonical): <https://github.com/grimmory-tools/grimmory> · <https://grimmory.org/>
- Grimmory packaging wrapper (volumes, `DISK_TYPE`, UID 1000 `bsd`, amd64):
  <https://github.com/daemonless/grimmory>
- BookBridge: <https://github.com/cporcellijr/bookbridge>
- Upstream BookBridge: <https://github.com/J-Lich/abs-kosync-bridge>
- Pinned nixpkgs (`nixos-26.05`) reading modules present:
  `audiobookshelf`, `calibre-web`, `kavita`, `komga`, `suwayomi-server`.
  **Absent:** grimmory, booklore, bookbridge.
- The pinned nixflix tree has **no** book module of any kind; its only mention of
  books is `"Readarr"` in Prowlarr's application-sync enum
  (`modules/prowlarr/applications.nix`).

---

## 3. Audiobooks live in two libraries, on purpose

Grimmory and Audiobookshelf are **both** pointed at the audiobook files, with
BookBridge reconciling progress. Owner's decision, 2026-09-15.

**The cost, stated plainly:** read/listen progress lives in two databases and
neither is authoritative. BookBridge reconciles them; it does not unify them, and
reconciliation has live failure modes upstream — e.g. *"Audiobookshelf progress
push gets stuck on wrong timestamp when a text-based client (KoSync) leads"*
(`cporcellijr/bookbridge` issue #434). Expect occasional disagreement about where
you are in a book, and expect the fix to be in BookBridge's matching rather than
in either library.

⚠ **This duplication is not a mistake to clean up.** A future reader who
"simplifies" it by deleting one library loses either the podcast feed reader or
the unified text+audio shelf. If it is ever undone, undo it deliberately, and
record the reason here.

---

## 4. Consequences already established

### 4.1 A container is the house pattern here, not an exception

`homepages.nix` already runs two OCI containers on galactica declaratively —
pinned image tag, per-file read-only config mounts, loopback-only publishes,
Traefik router pairs, sops templates for env. All three of Grimmory, MariaDB and
BookBridge follow that shape; none of them needs Dockge or Arcane (galactica runs
only the Arcane *agent*, `modules/nixos/arcane-agent.nix`).

### 4.2 Pin the image tags

⚠ With `pull = "missing"` — the fleet's pattern, see `homepages.nix` — a floating
`:latest` resolves **once** and then never updates again, which is the worst of
both worlds. Pin `vX.Y.Z` explicitly. `nightly`/`latest` are not candidates.
This is the same discipline `DECISIONS.md` §10 applies to the nixflix input:
pinned revisions, bumped deliberately, never by a routine update.

### 4.3 MariaDB is the first database engine on galactica — and it is Protected

There is currently **no** mysql/mariadb/postgres anywhere in galactica's config.
Two consequences:

1. **Tier.** `SHARES.md` §5's paired-appdata rule — *a service's `appdata`
   subtree inherits the highest tier of any data share it indexes* — puts
   Grimmory's state at 🛡 **Protected**, because `books` is Protected.
2. ⚠ **Backups need a dump, not a snapshot.** `BACKUP-BORG.md` selects ZFS
   datasets and snapshots them; a file-level snapshot of a *running* MariaDB is
   not reliably restorable. Grimmory's database needs a pre-snapshot
   `mariadb-dump` (borgmatic has a native MariaDB hook), and the two footguns
   already recorded for the deferred Immich Postgres hook apply unchanged:
   `format: plain` + `compression: none` so Borg can dedup, and a database hook
   silently forcing `read_special` tree-wide.

### 4.4 The BookLore database is probably recoverable — verify early

`MANUAL-STEPS.md` records that on 2026-09-03 sidepool's `pools/` — 117 GB of
Unraid `cache`/`fastservices`/`services` appdata — was rsynced to
**`tank/backups/sidepool-pools`** and `--checksum`-verified byte-identical. If
BookLore's MariaDB volume is in there, Grimmory's migration path turns shelves,
metadata and read-progress into an import instead of a rebuild.

**Do this before designing the import**, because the answer changes it:

1. [ ] Look for BookLore's appdata (and its MariaDB volume) under
       `/tank/backups/sidepool-pools`, and record what was found here.
2. [ ] Resolve the three-share books group **together** — `books` (Protected),
       `books_old` (suspected drop, "top level store for BookLore") and
       `calibre_books` (parked) — per `SHARES.md` §5's note that they are worth
       finishing in one pass rather than tripping over the leftovers later.

---

## 5. Acquisition

**Readarr is officially retired** (Servarr wiki, May 2024) and its metadata
servers are **gone** — so the `readarr` 0.4.18.2805 sitting in our nixpkgs pin is
a binary that cannot search or match a book at all. It is not a candidate.

Two services split the job, because they solve different halves of it:

### Chaptarr — the monitoring half

A Readarr fork grown into its own project, explicitly **not affiliated with the
Servarr team**. GPL-3, ~459 stars, 98 commits on `develop`, v0.9.925 (2026-08-09).
Ebooks **and** audiobooks in one instance with multi-edition support, so the
audiobook and ebook of a title sit side by side — which is exactly the shape §3
needs. Docker-only (building needs .NET 10 + Node + Yarn + FFmpeg; no binaries
are released). SQLite by default, optional external Postgres.

⚠ **Its metadata is a hard dependency on `api2.chaptarr.com`** — not
self-hostable, not configurable. This is the *same* dependency shape that killed
Readarr, and it is beta software by its own description ("Bugs are likely"; one
data-loss incident in pre-alpha, none in the six months since, 11,000+ users).

**Why that risk is accepted here — the load-bearing reason.** When Readarr's
metadata died it was fatal *because Readarr was the library manager*. In this
design **Grimmory owns the library** and does its own metadata lookup (Google
Books, Open Library). Chaptarr is only the acquisition front-end, so its database
is **disposable**: if `api2.chaptarr.com` disappears, what is lost is *new* author
and series matching — not the library, not the shelves, not read-progress.

⚠ Corollary, and it is a design constraint rather than a note: **nothing may come
to depend on Chaptarr's database being durable.** The day it becomes the only
place something lives, this whole argument stops holding.

⟨**Readarr + `rreading-glasses`** was the alternative that keeps metadata
self-hosted, and it is the more declarative one — `services.readarr` exists in the
pin. Rejected: it runs retired upstream code, and its ebook/audiobook handling is
precisely the awkwardness Chaptarr was forked to fix. Noted for the record that
rreading-glasses' author does not endorse Chaptarr — this is a live rivalry, not a
tidy succession, so revisit if Chaptarr stalls.⟩

### Shelfmark — the on-demand half

MIT, `calibrain/shelfmark`, **feature-stable and maintained best-effort** by
upstream's own description (core complete; new features out of scope are
declined). It is a search-and-fetch front end that **deliberately does not manage
a library** — it delivers to an ingest directory and stops. Metadata for
discovery from Hardcover, Open Library and Google Books; sources are Prowlarr
(indexers *and* clients), IRC, usenet, torrent, and direct HTTP (Anna's Archive
mirrors). Auth is single user/pass, forward auth, or OIDC. Upstream carries the
obvious legality disclaimer: what you have the right to download is on you.

**Why both.** Chaptarr monitors (authors, series, ongoing releases); Shelfmark
answers "I want this specific book now" and reaches sources Prowlarr cannot.
⚠ If Chaptarr's monitoring turns out to go unused, **Chaptarr is the first thing
to drop** — Shelfmark plus Grimmory's BookDrop is a complete, much smaller stack.

### Three findings that shape the implementation

1. **Use the `Lite` image and the FlareSolverr we already run.** Shelfmark's
   standard image bundles Chromium for Cloudflare challenges and wants ~2 GB RAM;
   `Lite` drops it and takes an external resolver. `nixflix.nix` already runs
   FlareSolverr — including the raised readiness probe that upstream's 30 s
   default breaks on a cold Chromium launch. Reuse it.
   ⚠ Upstream's named failure mode for a starved Chromium is repeated
   `403 detected; switching to bypasser` — if that appears, suspect memory, not
   the indexer.
2. ⚠ **Direct-download mode leaves the host's own IP.** In Prowlarr mode
   Shelfmark hands off to qBittorrent (already confined to the `wg` namespace) and
   nothing changes. In *direct* mode the container fetches over HTTP itself,
   unconfined. Confining it means `vpnConfinement` on a container unit — and then
   reaching loopback FlareSolverr needs the bridge address, the same wrinkle
   `nixflix.nix` documents for Traefik → the confined qBittorrent WebUI
   (`192.168.15.5`). Decide deliberately; do not let it default.
3. **Two ingest paths, kept separate on purpose.** Chaptarr imports into its own
   root folders; Shelfmark delivers into Grimmory's `/bookdrop`. Different
   destinations means the two acquisition paths never race for the same file, and
   Grimmory's watched-folder ingestion is what closes the loop for Shelfmark.

### Manga — Suwayomi

`services.suwayomi-server` is in the pin (with a nixpkgs manual page), which makes
manga **the only cleanly-solved piece of this stack**: a native module, no
container, no pinning debt. It downloads CBZ into the tree Grimmory already reads.
Comics/manga being new appetite (§1), there is nothing to migrate and no legacy
layout to honour.

⟨**Kapowarr** for Western comics was considered and deferred — not in nixpkgs, so
a third acquisition container and another pinned tag, for appetite that has not
been demonstrated yet. Add it if Suwayomi's coverage proves to be the gap.⟩

### Sources

- Readarr retirement: <https://wiki.servarr.com/readarr/status>
- Chaptarr: <https://github.com/Chaptarr/chaptarr>
- Shelfmark: <https://github.com/calibrain/shelfmark>
- `rreading-glasses` (the rejected alternative's metadata proxy):
  <https://github.com/blampe/rreading-glasses>
- Pinned nixpkgs: `readarr` 0.4.18.2805 is present and **not** marked broken or
  vulnerable — absence of a warning is not a signal of health here.

---

## 6. Storage layout — a separate dataset, inverting nixflix's rule

**Owner-confirmed 2026-09-15.** `tank/books` (and the audiobook tree) as their
**own dataset**, not a subdirectory of `tank/nixflix_media`.

This deliberately contradicts `nixflix.nix`'s "one layout rule", so the reasoning
matters:

- **Why that rule exists:** hardlinks cannot cross ZFS datasets, and the *arrs
  hardlink their imports. A new dataset under `nixflix_media` silently turns every
  import into a full copy — catastrophic for a 40 GB remux.
- **Why it inverts here:** `homelab:tier` is a **dataset property**. A
  subdirectory cannot carry its own tier, so books living inside `nixflix_media`
  would silently inherit the media stack's tier — and `books` is 🛡 **Protected**
  (`SHARES.md` §5). There is no way to have both the shared dataset and the
  correct tier.
- **Why the trade is cheap:** the cost of losing hardlinks scales with file size.
  An EPUB is megabytes; an audiobook is hundreds of megabytes to a few gigabytes.
  Against a 4×12 TB array, a copy-on-import is noise. The rule was never about
  hardlinks as a principle — it was about not duplicating video.

**So: correct tiering, copies accepted.** ⚠ Record this in `DECISIONS.md` too,
because a reader who knows the one layout rule will see a separate dataset as the
exact mistake that rule exists to prevent.

---

## 7. Exposure, names and auth

Settled 2026-09-15: **its own domain group** — `*.read.internal` and
`*.read.zjones.dev` — reached off-LAN over Tailscale, with **local accounts** for
now and OIDC as a follow-up.

| Service | Name |
|---|---|
| Grimmory | `grimmory.read.*` |
| Audiobookshelf | `audiobookshelf.read.*` |
| Chaptarr | `chaptarr.read.*` |
| Shelfmark | `shelfmark.read.*` |
| BookBridge | `bookbridge.read.*` |
| Suwayomi | `suwayomi.read.*` |

`read.*`, not `arr.*`: the reading stack is its own subsystem, and the *arr names
were chosen to follow the media stack (`traefik-galactica.nix`) — so borrowing
them would couple two stacks that relocate independently. The same reasoning
`configuration.nix` already applies to AdGuard, which sits under `galactica.*`
rather than `arr.*` precisely because it is not part of the media stack.

### ⚠ The new group needs ONE shared wildcard — this is the trap

Galactica runs **one** Traefik (`traefik-galactica.nix` owns `:80`/`:443` and the
firewall openings), so `read.*` is a **second domain group inside that instance**,
never a second module.

How that group gets its certificate is the part that can go quietly wrong.
AdGuard's router pair in `configuration.nix` is hand-written and therefore has no
wildcard to dedup against — `traefik-galactica.nix`'s shared `domains` covers only
`arr.zjones.dev` — so it requests **its own single-name LE cert**, which that
file's comment calls *"a one-time, deliberate cost, not a repeatable per-router
one."*

**Six services copying the AdGuard shape is exactly that repeatable cost:** six
individual certificates, against an allowance `traefik-galactica.nix` already
warns about (per-host `domains` lose a cold-start race and burn ~a fifth of the
weekly quota). So the implementation generalises `mkRouterPair`/`mkRouters` to
take a domain group with its own shared wildcard — declared **once** as
`*.read.zjones.dev` — rather than adding routers by hand.

### DNS

Four rewrites alongside galactica's existing block in `configuration.nix`
(galactica is `192.168.8.190`):

```nix
{ domain = "read.internal";      answer = "192.168.8.190"; }
{ domain = "*.read.internal";    answer = "192.168.8.190"; }
{ domain = "read.zjones.dev";    answer = "192.168.8.190"; }
{ domain = "*.read.zjones.dev";  answer = "192.168.8.190"; }
```

⚠ `enabled = true` comes from the `map` over the list — AdGuard's omitted bool
renders as Go's zero value and **silently disables every rewrite**.

### Off-LAN: Tailscale, not a new exposure surface

`services.tailscale` is already enabled on galactica (inline in
`configuration.nix`, with `tailscale0` trusted), and AdGuard already does
split-horizon. So the `.zjones.dev` names work from a phone off the LAN with **no
per-service exposure, no tunnel and no tsdproxy node**.

- ⚠ **Manual step, not Nix:** the tailnet must use AdGuard as its DNS (Tailscale
  admin console → nameservers) or the rewrites never resolve off-LAN.
- ⚠ **Use the `.zjones.dev` names on phones and tablets.** `*.read.internal`
  routers carry `tls = { }` — Traefik's self-signed default — which presents as a
  certificate warning on a mobile browser and outright failure in some apps. The
  `.internal` pair exists so the stack works on a LAN with no outbound path, not
  as the everyday name.
- ⟨**tsdproxy** was considered: it gives each service its own MagicDNS name, as
  the admin dashboard already has. Rejected for this stack — it is
  container-driven, so it would cover the five containers and leave native
  Audiobookshelf and Suwayomi needing a second mechanism. **Pangolin** was
  rejected as genuinely more exposed for no gain once Tailscale covers the use
  case.⟩

### Two wiring rules inherited from the *arr stack

1. ⚠ **Never hardcode `127.0.0.1` as an upstream.** `traefik-galactica.nix` derives
   every upstream from the service's own `connectionAddress`, because a confined
   service binds the namespace address instead. Shelfmark may end up confined
   (§5, finding 2), so it must follow the same rule rather than being special-cased
   later.
2. ⚠ **FlareSolverr stays unrouted.** It is deliberately absent from Traefik — an
   unauthenticated endpoint that fetches arbitrary URLs through a real browser.
   Shelfmark reaching it over loopback is consistent with that; do not add a route
   to make the wiring look tidier.

Also: the router names `dashboard` and `traefik` are reserved by an assertion in
`traefik-galactica.nix`. Nothing above collides, but a future addition could.

### Auth: local accounts, OIDC deferred

There is **no OIDC provider anywhere in this fleet** — no Authelia, Authentik,
Keycloak or Pocket ID, and no auth middleware on any Traefik router. So every
service uses its own login, with credentials in `secrets/galactica.yaml`.

Grimmory, Shelfmark and BookBridge all *speak* OIDC, so a provider later is
wiring rather than a rethink. ⟨Deferred deliberately: standing one up is its own
project with its own decisions, and it would hold the reading stack behind it.⟩

⚠ **BookBridge's own login matters more than its size suggests** — it holds
credentials for both libraries, so it is the one service where a weak local
password compromises everything else in this document.

---

## Still open

- ⚠ **Shelfmark's direct-download path and the VPN namespace** (§5) — the one
  exposure question §7 does not answer, because it is about outbound traffic
  rather than inbound. Decide deliberately rather than by default.
- **Secrets.** Every value `secrets/galactica.yaml` will need, and ⚠ the
  `nixflix.nix` precedent: *every* secret must exist before sops-nix activates or
  the switch fails.
- **Homepage entries.** `hosts/galactica/homepage/admin/services.yaml`, and
  whether any of it belongs on the guest dashboard. ⚠ `checks/homepage-config`
  fails the build if a widget references an API key its instance's env file does
  not define.
- **Borgmatic wiring** for the Protected MariaDB (§4.3) — the `mariadb-dump`
  hook, and whether it lands in `borgmatic.nix` alongside the still-deferred
  Immich Postgres hook.

### To verify before implementation

These are unknowns that change the design, not preferences. Each wants an answer
in this document.

1. [ ] **Does Chaptarr present as Readarr to Prowlarr?** Its docs do not mention
       Prowlarr at all; nixflix's app-sync enum only knows `"Readarr"`
       (`modules/prowlarr/applications.nix`). Probable as a fork, unverified.
2. [ ] **Does Chaptarr hardlink its imports?** Undocumented. §6 makes this cheap
       to get wrong either way, which is the point — but confirm it rather than
       assume it.
3. [ ] **Is BookLore's MariaDB volume in `tank/backups/sidepool-pools`?** (§4.4 —
       decides import versus rebuild.)
4. [ ] **Does `vpnConfinement` work on an `oci-containers` unit?** The fleet's
       only uses of it are native systemd services (`nixflix.nix`'s NAT-PMP
       sidecar). Needed for §5's finding 2.
5. [ ] **What database does BookBridge need**, and does it want the same
       pre-snapshot dump treatment as Grimmory's MariaDB? It ships alembic
       migrations; the type was not documented.
