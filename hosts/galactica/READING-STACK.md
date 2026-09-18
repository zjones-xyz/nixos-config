# galactica — the reading stack

The books/comics/audiobooks half of galactica, complementing the *arr media
stack (`nixflix.nix`, `MANUAL-STEPS.md` §12). Companion to `SHARES.md` (which
shares this inherits and their tiers) and `DECISIONS.md` (why, for anything here
that looks arbitrary).

**Status: spec settled, not implemented.** Every design decision is owner-settled
as of 2026-09-15 — the *client* half (§1–§4), the *acquisition* half and its
egress (§5), the storage layout (§6), exposure/names/auth (§7). What remains is
execution detail, not choices: secrets, the Homepage entries and the borgmatic
hooks; see "Still open" at the end.

**What is live once the base PR merges**, and it is deliberately little: the four
AdGuard rewrites, and the (empty) `read.*` domain group with its `readUpstreams`
entry point. ⚠ No service, no secret, no dataset — so the names resolve and then
404 against Traefik's default certificate until the first service registers, at
which point the wildcard is issued (see the certificate subsection in §7).

⚠ **Ten units for one subsystem** — Grimmory, MariaDB, Audiobookshelf,
BookBridge, Chaptarr, Shelfmark and Suwayomi, plus the confined proxy, the second
FlareSolverr that §5d adds, and the gid oneshot §4.7 needs — on top of reusing Prowlarr, the shared
FlareSolverr, qBittorrent and SABnzbd from the *arr stack. That is the deliberate
price of covering four content types with two overlapping libraries and keeping
the acquisition egress in the tunnel; §3 and §5 name the pieces to drop first if
it proves more than it is worth.

---

## 1. Scope

All four content types are in: **ebooks, comics/manga, audiobooks, podcasts.**

| Service | Owns | Shape | In nixpkgs? |
|---|---|---|---|
| **Grimmory** | ebooks, comics/manga, audiobook files | OCI container + **MariaDB** | ❌ container only |
| **Audiobookshelf** | audiobooks, podcasts | `services.audiobookshelf` | ✅ native module |
| **BookBridge** | read/listen progress sync between the two | OCI container + SQLite | ❌ container only |
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
   silently forcing `read_special` tree-wide. ⚠ It is not the only database here —
   BookBridge's SQLite needs its own treatment, §4.5.

### 4.4 ~~The BookLore database is probably recoverable — verify early~~ — moot: starting empty

`MANUAL-STEPS.md` records that on 2026-09-03 sidepool's `pools/` — 117 GB of
Unraid `cache`/`fastservices`/`services` appdata — was rsynced to
**`tank/backups/sidepool-pools`** and `--checksum`-verified byte-identical. If
BookLore's MariaDB volume is in there, Grimmory's migration path turns shelves,
metadata and read-progress into an import instead of a rebuild.

⭐ **Owner's decision, 2026-09-17: start empty.** The Unraid `books` data was
copied into the array but sits in a dataset that has not been migrated yet, and
`tank/books` is empty (verified on the host). Grimmory comes up on a fresh
library; moving the old collection in is a **separate, later job**. So the
BookLore database question below is **not blocking** — it only matters if and
when that import happens, and the files matter more than the shelves either way.

⟨Kept rather than deleted because the recovery path is the part worth not
rediscovering:⟩

1. [ ] Look for BookLore's appdata (and its MariaDB volume) under
       `/tank/backups/sidepool-pools`, and record what was found here.
2. [ ] Resolve the three-share books group **together** — `books` (Protected),
       `books_old` (suspected drop, "top level store for BookLore") and
       `calibre_books` (parked) — per `SHARES.md` §5's note that they are worth
       finishing in one pass rather than tripping over the leftovers later.

---

### ⚠ Aside: `audiobookshelf.dataDir` is a name, not a path

Small but it invalidates an assumption: this document says service state belongs
under `/tank/appdata/<service>` "matching `nixflix.nix`", which reads as if the
module supports it. It does not — `services.audiobookshelf.dataDir` is a *name*
under `/var/lib`, used as `StateDirectory`. Moving its state onto the appdata
mirror means overriding `ExecStart` to pass absolute `--config`/`--metadata`.

### 4.5 ⚠ BookBridge holds the keys to everything else — verified 2026-09-15

Read out of BookBridge's source at tag `7.6.0`. It is **SQLite only**
(`/data/database.db`; no Postgres or MySQL anywhere in the tree), runs as **root**
inside the container (no `USER` directive, no `PUID`/`PGID`, non-root untested by
upstream), and serves on **one port, 5757** — on Flask's **Werkzeug development
server**, with no gunicorn or waitress. It stays behind Traefik; it is never
exposed directly.

**Why its data outranks its size.** BookBridge must replay credentials verbatim to
the services it syncs, so it stores them Fernet-encrypted in its own database —
including the Audiobookshelf **API token** and, notably, **Grimmory's account
password** (a real password, not a token). `database.db` **plus** `secret.key`
together therefore decrypt every linked account. Upstream says as much outright:
*"Protect it like the server itself."*

**So set `BOOKBRIDGE_SECRET_KEY` from sops.** Left unset, BookBridge generates the
key into `/data/secret.key` — i.e. beside the ciphertext it protects, which makes a
stolen dataset snapshot a full credential leak. Supplied from sops (env only; it is
deliberately never read from the DB), the same snapshot is inert ciphertext. Also
worth setting `WEB_SECRET_KEY`, so sessions survive a restore.

⚠ **A live file copy of its data directory is NOT a valid backup.** It runs in
**WAL** mode on local storage with `synchronous = NORMAL`, so `database.db`,
`-wal` and `-shm` copied at different instants restore stale or inconsistent, and
taking `database.db` alone silently loses everything since the last checkpoint.
Three workable shapes, in upstream's order of preference:

1. **Dump first**, via the script the image already ships
   (`/app/scripts/backup_db.sh` — SQLite's online-backup API plus
   `PRAGMA integrity_check`), then snapshot `/data` excluding its own
   `backups/`. This is the only path that verifies integrity.
2. **Stop → snapshot → start**, upstream's "safest simple backup".
3. A **ZFS snapshot alone** is filesystem-atomic, so it captures the three files at
   one instant and SQLite recovers it — acceptable, and worth pairing with (1)
   for the integrity check.

⚠ Two restore traps: a database restored **without its matching key** leaves every
credential undecryptable (it presents as settings reading "not configured"), and
only a whole-`/data` backup preserves `audio_cache/`, without which transcripts are
recomputed from scratch.

⚠ **Keep `/data` on local storage.** On NFS/CIFS/fuse BookBridge silently
downgrades to `DELETE` journal mode — relevant on a host that exports NFS for a
living.

Two fixed points for the implementation: **`DATA_DIR` must stay `/data`** (its
Alembic config hardcodes that path and never consults the variable, so a custom
`DATA_DIR` has migrations and the app pointing at different files), and
**`KOSYNC_PORT` stays unset** — split-port mode is purely additive, KOSync already
works on 5757, and Traefik narrows routes better anyway. Pin
`ghcr.io/cporcellijr/bookbridge:7.6.0` (GHCR only; the `-cuda` variant is ~800 MB
larger and only for NVIDIA Whisper, which this host has no GPU for).

### 4.6 BookBridge reaching Audiobookshelf — resolved, it can

Found while implementing, and it goes to whether BookBridge can do its job.
Its sync targets are configured in its own UI, and **from inside a container
`127.0.0.1` is that container's own namespace** — so the loopback publishes the
rest of this stack uses are not reachable from it.

- **Grimmory it can reach**: both are containers on the `proxy` network, so
  Docker's embedded DNS resolves `http://grimmory:6060`.
- ⚠ **Audiobookshelf it may not.** It is native and bound to `127.0.0.1`, so the
  only route is its Traefik name — and **Docker refuses a loopback nameserver**
  from the host's `resolv.conf`, falling back to public DNS, where
  `*.read.zjones.dev` does not exist. The container therefore may never resolve
  the name at all.

**Verify on the host before trusting the sync.** If it fails, two levers, and the
choice is not obvious:

1. `--add-host` pinning `audiobookshelf.read.zjones.dev` to `192.168.8.190`.
   Keeps the real wildcard certificate; costs a hardcoded address in Nix.
2. Bind Audiobookshelf where the bridge can see it, plus
   `networking.firewall.interfaces."docker0".allowedTCPPorts`. No hardcoded
   address; widens what else on the bridge can reach it.

⚠ Do **not** reach for `audiobookshelf.read.internal` — that hands BookBridge
Traefik's self-signed certificate, which §7 already warns about for apps.

**✅ Verified on the host 2026-09-17: it reaches it, and neither lever is
needed.** `https://audiobookshelf.read.zjones.dev/ping` answers `200` from
inside the container, over the real wildcard certificate.

The premise above was wrong in one detail, and that detail is the whole
outcome: galactica's `/etc/resolv.conf` is **Tailscale's**, not a loopback
nameserver. The container's resolver reports
`ExtServers: [host(100.100.100.100)]`, so Docker had a forwardable upstream and
never hit the loopback refusal — MagicDNS resolves the name to `192.168.8.190`
and Traefik does the rest.

⚠ Which means the path depends on something declared nowhere in this stack:
the tailnet's DNS knowing the `read.zjones.dev` rewrite. Note also that a
public resolver could not return a private address, so the fact that this works
is itself evidence about item 2 of the run book's §18. If BookBridge ever
loses Audiobookshelf, suspect resolution before suspecting either service —
and lever 1 above is then a one-line hedge that removes DNS from the path
entirely.

### 4.7 ⚠⚠ BLOCKING: two nixflix modules wipe the `media` group

**Root cause found, and it is upstream's.** `config.users.groups.media` carries
**two `mkForce { }` definitions** — from nixflix's `torrentClients/qbittorrent.nix`
and its `navidrome` module. `mkForce` is priority 50, so it beats nixflix's *own*
`users.groups.media = { gid = globals.gids.media; members = mediaUsers; }` at
normal priority, and beats anything this fleet adds. Established by reading
`options.users.groups.definitionsWithLocations` on the evaluated host, after a
literal `gid = 1699` in our own module was silently discarded.

Consequences, in order of how much they matter:

1. ⚠ **`media` has no gid at evaluation time**, so nothing can hand a container a
   numeric `PGID`/`GROUP_ID`. `toString null` renders the **empty string**, which
   container entrypoints read as "use my default group" — silently placing what
   they write outside `media`. Both acquisition containers therefore ship with
   **no `PGID` at all** and cannot write into the shared `root:media` trees; the
   file says so at the top.
2. ⚠ **`nixflix.globals.gids.media` (169) is a constant the host does not
   honour.** Do not trust it anywhere.
3. ⚠ **`z` is not in the `media` group.** The evaluated members are
   `["unpackerr"]` — contributed by `unpackerr.nix`'s `extraGroups`, not by
   `nixflix.mediaUsers = [ "z" ]`, which the same `mkForce` discards. **This
   affects the existing media stack, not only the reading stack.**

**Four ways out — owner's decision. The fourth looks best.**

1. ⭐ **Resolve the gid at *runtime*, not at evaluation.** It does not exist when
   Nix evaluates, but it does exist when a unit starts. A `oneshot` writes
   `PGID=$(getent group media | cut -d: -f3)` into an env file under `/run`, and
   each container adds that file to `environmentFiles` (read by `docker run
   --env-file` at start) and orders after it. **Touches no live group, needs no
   nixflix patch, renumbers nothing, and self-corrects if the gid ever moves.**
2. **`lib.mkOverride 40` — but on the WHOLE submodule value, not on `.gid`.**
   ⟨In-repo precedent for the *class* of problem: `configuration.nix` now pins
   `users.users.z.uid = 1000` for exactly this reason — an unpinned `uid` is null
   at evaluation time, and everything interpolating it "was silently rendering an
   empty string". Same failure, same fix shape.⟩
   ⚠ The nested form silently does nothing: the `mkForce`es apply to the
   `users.groups.media` *value*, and `filterOverrides` discards every
   normal-priority definition at that level **before** the submodule is
   evaluated, so a priority-40 marker nested inside one is never seen. This was
   reproduced against the pinned `lib`. The form that works is
   `users.groups.media = lib.mkOverride 40 { gid = <n>; };`
   It is also safer than it sounds: `members` comes from the group submodule's
   *own* `config` block, derived from every user's `extraGroups` — which is why
   `["unpackerr"]` survives the `mkForce` today — so overriding the whole value
   keeps that membership. Getting `z` in is then
   `users.users.z.extraGroups = [ "media" ]`, not `members`. ⚠ Still read
   `getent group media` first: if the live number differs from what you pin, plan
   a recursive `chgrp` over `/tank/nixflix_media`.
3. **A fourth hand-carried nixflix patch** (`DECISIONS.md` §10 tracks three)
   removing the two `mkForce`es. Fixes the cause, restores `z`'s membership at
   normal priority, and adds to the carried debt.
4. ~~**A dedicated `reading` group.**~~ ⚠ **Dead, not merely imperfect.**
   Chaptarr's cleanup path needs **unlink** rights in nixflix's downloads
   directory, which nixflix's own tmpfiles pin at `root:media 0775` — a
   `reading`-grouped service cannot delete there at all.

⟨A fifth, uglier option if none of the above appeals: default POSIX ACLs granting
the two uids rwx on the shared trees via `systemd.tmpfiles` `a+` lines — no gid
needed anywhere, at the cost of ACLs on the array.⟩

**Chosen: route 1, implemented.** `reading-media-gid.service` is a oneshot that
reads `getent group media` and writes `PGID=<n>` into `/run/reading/media-gid.env`;
both acquisition containers take that as an `environmentFiles` entry and order
after it. ⚠ It **fails loudly** if the group has no gid rather than writing an
empty `PGID`, which is the silent miswrite this whole section exists to prevent.
Nothing live is touched and no nixflix patch is carried.

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

#### Chaptarr's runtime knobs — verified in source, 2026-09-15

Read out of Chaptarr's own source (`develop`), not inferred from the fork:

- ⚠ **`PUID`/`PGID` default to `99:100`** — Unraid's `nobody:users`, inherited
  from its Docker-first heritage. Wrong for this host: they must be set to match
  the dataset's ownership or every import lands unreadable.
- ⚠ **`UMASK`** is honoured by the entrypoint, and upstream recommends `002` when
  other containers share the media group. Same fix, same reason as the
  `UMask = "0002"` override `nixflix.nix` already applies to qBittorrent.
- ⚠ **`CopyUsingHardlinks` is not declarable.** It lives in the `Config` table of
  `chaptarr.db`; env vars only reach `config.xml`-level settings (port, API key,
  log level). So it is UI state or a one-shot
  `PUT /api/v1/config/mediamanagement`. Its default is `true`, which is harmless
  here — see §6 — so the honest answer is to leave it and note it in
  `MANUAL-STEPS.md` rather than pretend Nix owns it.
- **Seeding is preserved by default.** An import is Copy (not Move) until the
  download client reports the item removable, so the torrent stays put. Chaptarr
  adds a per-indexer **"Keep seeding permanently"** and a per-client
  `copyUnmanagedDownloads`; ⚠ conversely, without `Remove Completed Downloads`
  plus real seed limits, copies accumulate on the downloads dataset forever.
- ⚠ **Log level wants staying at Info** — that is where the import path reports
  which transfer it actually performed (§6).

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
2. ⚠⚠ **Direct-download mode leaves the host's own IP, and the obvious fix
   silently does not work.** In Prowlarr mode Shelfmark hands off to qBittorrent
   (already confined to `wg`) and nothing changes. In *direct* mode the container
   fetches over HTTP itself. **See §5a** — putting `vpnConfinement` on the
   container's unit evaluates cleanly and confines nothing.
3. **Two ingest paths, kept separate on purpose.** Chaptarr imports into its own
   root folders; Shelfmark delivers into Grimmory's `/bookdrop`. Different
   destinations means the two acquisition paths never race for the same file, and
   Grimmory's watched-folder ingestion is what closes the loop for Shelfmark.

### 5b. Chaptarr ↔ Prowlarr: the protocol matches, the sync is unproven — 2026-09-15

**The good half, verified in both codebases** (not inferred from the fork):
Chaptarr serves `/api/v1` with `X-Api-Key`, keeps both Newznab and Torznab
implementations, and its own settings carry Prowlarr-specific fields whose help
text reads *"Only needed when this indexer was added via Prowlarr."* Prowlarr's
Readarr app calls only `/api/v1/indexer*` and `/api/v1/system/status`, with **no
version or app-identity check**. So:

- **Use `implementationName = "Readarr"`.** ✅ **No nixflix enum change is needed** —
  its application list is already complete and correct.
- None is coming upstream either: Prowlarr #2578 (rename to Chaptarr) is **closed
  as not planned**; #2772 (add Chaptarr) is open and untriaged, and itself names
  Readarr as the workaround.
- ⚠ **Port 8789**, not Readarr's 8787 — `baseUrl` must be explicit.

**The bad half: two open, unacknowledged Chaptarr bugs sit directly on the sync
path.** Both filed within the last month, neither with a maintainer response, no
fix through 0.9.964.0:

- **#84 — HTTP 500 on `GET /api/v1/indexer/schema`.** Prowlarr's app test fails
  ("cannot connect to Readarr"); an identical `curl` from the same host succeeds,
  and nothing reaches Chaptarr's request log, so it throws in early middleware.
  That endpoint feeds Prowlarr's schema cache, so it blocks the test **and all
  syncing**.
- **#131 — 400 on indexer create, and `forceSave` does not rescue it.** Chaptarr
  tests on create whenever the definition is enabled (which Prowlarr always sets),
  and hard validation errors throw regardless — so `forceSave` suppresses only
  *warnings* and the indexer never lands.

⚠ **Treat Prowlarr → Chaptarr sync as unproven on this fleet until tested on the
host.** It is the single biggest risk in this document. **The escape hatch, and it
is a real one:** Chaptarr accepts **hand-entered Newznab/Torznab indexers** pointed
straight at the indexer, bypassing Prowlarr entirely. And note Shelfmark talks to
Prowlarr *directly* for both indexers and clients (§5), so it is unaffected — if
Chaptarr's sync will not come up, the on-demand half of the stack still works.

**⚠ The silent failure mode: category mismatch.** Chaptarr routes by media type —
audiobook searches use only selected **Audio (3000–3999)** categories, ebook
searches only **Books (7000–7999)** — and Prowlarr's category matching is an
**exact-ID intersection with no parent→child expansion**. So an indexer advertising
`3000 Audio` but not `3030 Audio/Audiobook` gets *no* audio category pushed:
**ebook search works while audiobook search issues zero queries and reports "No
results found"**, indistinguishable from a genuinely empty result (Chaptarr #128).
**Mitigation: widen the synced categories to include `3000` and `3030`.** Related
quiet behaviour: an empty intersection makes Prowlarr skip the indexer with only a
`Debug` log, and a FullSync *deletes* a previously-synced indexer that stops
matching.

**Two nixflix gotchas for whoever implements this:**

1. ⚠ `prowlarr.config.applications` is `mkDefault`, and the `prowlarr-applications`
   unit **deletes every Prowlarr application not in the configured list**. Adding
   Chaptarr by assigning the option replaces the whole list — **Sonarr, Radarr and
   Lidarr must be re-listed** or they are wiped.
2. ⚠ `prowlarr-applications.service` orders itself after radarr/sonarr/
   sonarr-anime/lidarr only, and the script runs `set -eu` and exits 1 on a failed
   PUT. Nothing orders it after a Chaptarr unit, so a cold boot can fail before
   Chaptarr is listening — add Chaptarr to its `after`/`requires`.

⟨Undetermined and worth a diagnostic: Chaptarr exposes media-type-scoped roots
(`/ebook/api/v1/…`, `/audiobook/api/v1/…`). Pointing Prowlarr at the plain root
looks right — indexers carry no media-type field — but that is read from code, not
documented, and scoping the app URL is worth trying if #84 or #128 bite.⟩

### 5a. ⚠⚠ `vpnConfinement` does not work on a Docker container — verified 2026-09-15

**This is the most dangerous finding in this document**, because it fails in the
direction that looks like success.

`systemd.services."docker-<name>".vpnConfinement` **type-checks, merges, and
renders** `NetworkNamespacePath=/run/netns/wg` onto the generated unit. But with
the Docker backend that unit's process is the **`docker` CLI client** — the
container itself is created by `dockerd`, a different unit with no namespace
path. So the confinement moves the *client* into the tunnel and leaves the
container in dockerd's namespaces.

**What you would observe:** the unit starts, `-p 127.0.0.1:…` still publishes
(dockerd does that), the app works — and every packet leaves on the host's own
IP. ⚠ **Nothing in the config, the unit, or the logs says "not confined."**
`--network=host` makes it strictly worse: host mode means *the daemon's*
namespace, i.e. the initial one.

⟨**Podman would work** — there the container is a descendant of the unit, and
podman also accepts `--network=ns:/run/netns/wg`, which Docker's `--network` does
not (it takes only `bridge|host|none|container:<id>|<name>`). It is not available
to us: `virtualisation.oci-containers.backend` is one global enum for the host and
`traefik-galactica.nix:214` sets `docker` deliberately, for the socket proxy, the
Beszel agent and Dockge. Flipping it would move **every** container on galactica.⟩

**The pattern that does work: confine a native proxy, leave the container on the
bridge.** Shelfmark only needs *outbound HTTP* in the tunnel, so the tunnel-side
process can be a native unit:

- A native `tinyproxy`/`privoxy` listening on `vpnNamespaces.wg.namespaceAddress`
  (`192.168.15.1`), with `vpnConfinement` on **its** unit — a real systemd
  service, where confinement works.
- `vpnNamespaces.wg.portMappings` for the proxy port. ⚠ `openVPNPorts` is the
  wrong tool: it opens on `wg0`, not the veth.
- The Docker bridge subnet added to `nixflix.vpn.accessibleFrom`, or the proxy's
  replies route down the tunnel instead of back to the container. ⚠ That subnet
  must be **pinned** (the shared `proxy` network has no fixed subnet today) or the
  config drifts silently.
- The container gets `HTTP_PROXY`/`HTTPS_PROXY`/`NO_PROXY` and keeps ordinary port
  publishing, so its Traefik route is unchanged.
- ⚠ If Shelfmark cannot be made to honour a proxy, the honest answer is *"not
  confinable on this host as a container"* — not a workaround.

⟨Rejected: a gluetun-style VPN container plus `--network=container:vpn` is the
mainstream Docker answer, but it means a **second** ProtonVPN WireGuard session —
second config, second port-forward, and the NAT-PMP sidecar does not cover it.⟩

**For anything that genuinely does run inside the namespace**, three things must
all hold, and none is `networking.firewall.allowedTCPPorts`:

1. It must **bind the namespace address**, never loopback — the same reason
   `nixflix.nix` has Traefik dial `connectionAddress`.
2. Reaching a host-loopback service (FlareSolverr on `8191`) means dialling the
   **bridge address `192.168.15.5`**, plus `vpnNamespaces.wg.allowedEgress` for
   that destination — ⚠ the single address, **not** `192.168.15.0/24`, which
   collides with the connected veth route and fails `wg.service` on switch — plus
   `networking.firewall.interfaces."wg-br".allowedTCPPorts`. Nothing in this repo
   touches `wg-br` today.
3. LAN reachability comes from `portMappings` **and** `accessibleFrom` together;
   because the packet is DNAT'd it is forwarded, so the host firewall never sees
   it and the netns INPUT rule is the real gate.

### 5c. Shelfmark's egress, read from source — 2026-09-15

**The short version: Shelfmark downloads every byte itself; FlareSolverr only
fetches *challenged pages*.** So confining Shelfmark is not pointless — but it is
not sufficient either, and two paths cannot be confined at all.

| Phase | Whose IP touches the origin |
|---|---|
| Search / metadata / md5 and partner pages | **Shelfmark** (direct-first) |
| Any page that comes back challenged | **FlareSolverr** — it fetches the page and returns the body |
| welib pages | **FlareSolverr** always (forced) |
| **The file bytes, and resume** | **Shelfmark** (`requests`, `stream=True`) |

⚠ **Corrects an earlier claim in this document's history:** "Prowlarr mode leaks
nothing" was wrong. Even handing off to a download client, Shelfmark **fetches the
`.torrent` itself from arbitrary tracker origins** to recover the info_hash, and on
the NZBGet path always fetches the NZB itself. Only the *payload* transfer is
delegated.

#### The proxy lever, and the trap in it

Shelfmark honours an outbound proxy — **no client is built with `trust_env`
disabled anywhere**, and there is no `aiohttp`. But it has two mechanisms and they
cover different ground:

- ⚠ **Set it in Shelfmark's web UI and you cover 8 of ~52 call sites.** Metadata
  providers, cover art, `.torrent`/`.nzb` fetches, debrid APIs and OIDC all go
  **direct**. This is a silent trap.
- ✅ **Set it as container environment variables and all ~52 are covered**, via
  `requests`' `trust_env`. That is the lever to use.

Two further traps if env vars are used:

- ⚠ **`NO_PROXY` semantics differ between the two mechanisms.** Shelfmark's own is
  `fnmatch` (`10.*` works); the env path is urllib/requests **suffix** matching,
  where `10.*` matches nothing. So the LAN services (Prowlarr, qBittorrent,
  SABnzbd, Grimmory) must be listed in requests-compatible form or they are dialled
  through the proxy.
- ⚠ **The POST to FlareSolverr does not pass `proxies=`**, so FlareSolverr's host
  must be in `NO_PROXY` or Shelfmark tries to reach it *through* the proxy.

#### Two things no proxy can cover

1. ⚠ **FlareSolverr's own fetches.** Shelfmark's request payload to it is only
   `cmd`/`url`/`maxTimeout` — **there is no per-request `proxy` field**, so the
   tidy idea of tunnelling FlareSolverr per-request without confining the shared
   service **is not available** (it would need a ~3-line patch to carry). The
   alternative is confining the FlareSolverr *service* — which works, since it is
   native — but that pushes **Prowlarr's indexer scraping** into the tunnel too.
2. ⚠⚠ **IRC and DCC cannot be proxied at all.** Raw TCP sockets, no SOCKS
   monkey-patching anywhere; upstream's own settings text says DCC needs direct
   connections to arbitrary ports. **Only a network namespace could contain this,
   which is exactly what Docker cannot give us** (§5a). If IRC is used, it egresses
   on the host's IP, full stop.

#### Two behaviours worth knowing regardless

- ⚠ **It phones Anna's Archive on boot.** About 15 s after start a daemon thread
  runs a throwaway search to pre-warm the challenge path — egress with no user
  action, on every restart.
- It replaces `socket.getaddrinfo` **process-wide** with a DoH resolver
  (Cloudflare/Google/Quad9/OpenDNS, rotating on failure), so its name resolution
  does not use the host's AdGuard.
- No telemetry, update check or analytics found in the server code.

### 5d. Decided: a dedicated confined FlareSolverr — owner-settled 2026-09-15

Shelfmark's HTTP egress goes through the tunnel; its challenged-page fetches go
through a **second FlareSolverr of its own**; **IRC is disabled.** The shape:

1. **A native proxy confined to `wg`** (`tinyproxy`/`privoxy`), listening on the
   namespace address — confinement works here because it is a real systemd
   service (§5a).
2. **The proxy reaches Shelfmark as container environment variables**, never as
   its web-UI setting: env covers all ~52 outbound call sites, the UI setting
   covers 8 (§5c). ⚠ `NO_PROXY` must be written in **requests-compatible suffix
   form** (not `10.*`) and must list the dedicated FlareSolverr, Prowlarr,
   qBittorrent, SABnzbd and Grimmory — the call to FlareSolverr passes no
   `proxies=`, so without the exclusion Shelfmark dials it *through* the tunnel.
3. **A second FlareSolverr, confined, on its own port, for Shelfmark alone.**
   ⚠ It needs the same raised readiness probe the shared one already carries
   (`nixflix.nix`): upstream's 30 s probe dies inside a cold Chromium launch, an
   `ExecStartPost` failure kills the unit, and `TimeoutStartSec` must move with it.
4. ⚠ **Prowlarr's FlareSolverr stays on loopback, untouched.** Two reasons, and
   both are the point of this arrangement rather than incidental:
   - `nixflix` **hardcodes** `http://127.0.0.1:8191` for Prowlarr's indexer proxy
     (`modules/prowlarr/indexerProxies.nix:67`). Confining the shared instance
     breaks that and buys a fourth hand-carried nixflix patch (`DECISIONS.md` §10).
   - Routing indexer scraping through a VPN exit is actively harmful: private
     trackers commonly block or flag datacenter ranges, and **Cloudflare is
     harsher on known VPN ranges — so it would make FlareSolverr worse at the only
     job it has.**
5. ⚠ **IRC and DCC are disabled, not merely unused.** They are raw TCP with no
   SOCKS support at any layer (§5c); only a network namespace could contain them,
   and Docker cannot give us one (§5a). Disabled in configuration **with this
   reason recorded beside it**, so that switching a source on later is a
   deliberate act and not an accident that quietly egresses on the house IP.
6. Neither FlareSolverr instance is routed through Traefik — the existing rule in
   `traefik-galactica.nix`, and it applies to the new one unchanged.

**What remains uncovered, knowingly:** nothing, once IRC is off — with one
footnote. Shelfmark still **searches Anna's Archive ~15 s after every start**
(§5c); that egress is proxied like any other, so it rides the tunnel, but it
happens with no user action and is worth knowing when reading logs.

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
**own dataset**, not a subdirectory of `tank/nixflix_media`; copy-on-import
accepted.

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

### What the source actually does — verified 2026-09-15

Chaptarr's `DiskTransferService.TransferFile` uses `HardLinkOrCopy` for imports, so
across datasets:

- The `link()` attempt fails `EXDEV`, is caught, logged at **Trace**, and returns
  false. **No exception, no failed import** — the copy path is a designed
  fallback, not an error path.
- It then logs at **Info** which transfer it performed, with both mount roots and
  filesystem types — a Chaptarr addition (upstream Readarr logs nothing here) with
  a regression test behind it. That line is the only way to tell the two outcomes
  below apart.
- ⟨**A ZFS surprise, in our favour:** when *both* sides are ZFS it first tries a
  **reflink** (`FICLONE`), which is a block clone — near-instant and near-free.
  Conditions: same pool, `feature@block_cloning` active, `zfs_bclone_enabled=1`,
  x86_64. ⚠ That tunable has **defaulted to 0** in released OpenZFS 2.2.x since
  the 2023 block-cloning corruption bug, and what nixos-26.05 ships is unverified
  — so plan for honest copies and treat reflinks as a bonus if the log says
  `created reflink instead`. Do **not** enable the tunable to chase it.⟩

**A second argument for the separate dataset, found while verifying the first.**
Chaptarr has a `FileMutationSafetyService` that exists because mutating a
*hardlinked* import (audio tag writing, `FileDate`, chmod) would corrupt the file
the torrent client is still seeding; it works around this by copying to a sibling
and moving it over. Across datasets there are no hardlinks, so **that entire class
of "Chaptarr retagged my seeding torrent" problem cannot occur.** The separate
dataset is not merely affordable here — it is the safer arrangement.

**The costs, stated honestly:**

- ⚠ **Space doubles until the torrent is removed.** Size the downloads and library
  datasets to hold both concurrently, not either/or.
- ⚠ **There is effectively no pre-import free-space guard on the copy path**
  (inherited from Readarr, not a Chaptarr regression). A full library dataset
  presents as a failed-and-rolled-back copy rather than a pre-flight rejection.
  The copy is size-verified with rollback, so the failure is clean — a missing
  book, never a truncated one.
- ⚠ **If the ebook and audiobook roots end up on *different* datasets**, Chaptarr's
  ebook-colocation replica files are full copies too, and are deleted and
  recreated on every upgrade — write churn on whichever dataset holds them. Keep
  both roots on `tank/books` unless there is a reason not to. (Related open
  upstream issue: `RescanAuthor` walks only a single path.)

⚠ **Podcasts need a dataset of their own, and §6 did not say so.** §1 inherits
`podcasts_audiobookshelf` at ✅ **Re-acquirable** while `books` is 🛡 Protected —
and this section's whole argument is that tier is a *dataset* property. Podcasts
under `/tank/books` would therefore be backed up as Protected forever, which is
exactly the over-classification `SHARES.md` §5 warns against. A separate
`tank/podcasts` at Re-acquirable.

**So: correct tiering, copies accepted.** ⚠ Record this in `DECISIONS.md` too,
because a reader who knows the one layout rule will see a separate dataset as the
exact mistake that rule exists to prevent.

---

## 7. Exposure, names and auth

**Owner-settled 2026-09-15:** its own domain group — `*.read.internal` and
`*.read.zjones.dev` — reached off-LAN over **Tailscale**, with **local accounts**
now, OIDC as a follow-up, and **Pangolin deliberately deferred until after that
follow-up lands** (§7's phasing below).

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

### ⚠ What an empty group means for the certificate — and why the rollout is staged

Verified while implementing the group: **an empty group publishes no router, so
it requests no certificate at all.** The `*.read.zjones.dev` wildcard is issued
the moment the *first* reading service registers in `homelab.readUpstreams`.

That first issuance goes straight to **production**: `letsencryptStaging = false`
is already set for this host, and there is no staging dry-run available for one
group — flipping the flag would move the media stack's certs to staging storage
too and warn on every `*.arr.zjones.dev` name meanwhile.

⚠ **The allowance is shared with the media stack.** Production allows 50
certificates per **registered domain** per week, and `read.zjones.dev` and
`arr.zjones.dev` are both `zjones.dev` — the same budget `MANUAL-STEPS.md` §12
item 6 records spending **ten** of, when `arr`'s un-deduped first switch issued
per-subdomain certificates before the wildcard arrived.

**So the rollout is staged deliberately: land one service, check the journal for
exactly one issuance, then add the rest.** `MANUAL-STEPS.md` §18 item 1 carries
the command and what to look for.

### ⚠ Router names are flat across groups

A hazard this group *introduces*, and worth stating because the module now guards
it: router and service names are **group-independent** (`<name>`, `<name>-dev`,
`<name>-svc` — no group prefix). The attrset merge means a name claimed in two
groups would **silently drop one of the two routes** rather than failing. §5b's
Chaptarr-as-Readarr discussion makes a collision imaginable. An assertion now
rejects it by name, alongside the existing `dashboard`/`traefik` reservation —
which is reserved in *every* group, since a `traefik.*` service would be a trap
under any domain.

⟨Minor and symmetric with `arr`: the apex rewrites (`read.internal`,
`read.zjones.dev`) resolve, but no router serves an apex in either group, so they
answer 404 from Traefik's default certificate. Not a "reachable name".⟩

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
- ⚠ **Tailnet reachability is all-or-nothing for the group.** The wildcard rewrite
  resolves every name under `*.read.zjones.dev`, so once the tailnet uses AdGuard,
  the *acquisition* UIs (Chaptarr, Shelfmark, Suwayomi) are reachable off-LAN too,
  not only the readers. That is the accepted default — the tailnet is a private
  device set, so narrowing it buys little. If it is ever unwanted, the lever is a
  Traefik source-IP middleware or a second name group, **not** DNS.
- ⟨**tsdproxy** was considered: it gives each service its own MagicDNS name, as
  the admin dashboard already has. Rejected for this stack — it is
  container-driven, so it would cover the five containers and leave native
  Audiobookshelf and Suwayomi needing a second mechanism.⟩

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
wiring rather than a rethink. BookBridge additionally implements
**trusted-proxy header auth** (`REMOTE_AUTH_ENABLED`/`REMOTE_AUTH_HEADER`/
`REMOTE_AUTH_TRUSTED_PROXIES`) — undocumented upstream but present in 7.6.0, and
⚠ it defaults to loopback-only, so Traefik's address must be listed explicitly for
it to work at all. ⟨Deferred deliberately: standing one up is its own
project with its own decisions, and it would hold the reading stack behind it.⟩

⚠ **BookBridge's own login matters more than its size suggests** — it holds
credentials for both libraries (§4.5), so it is the one service where a weak local
password compromises everything else in this document.

### The phasing, and why Pangolin waits

1. **Now (this spec).** LAN plus tailnet, local accounts per service.
2. **Follow-up spec.** An OIDC provider, then wire the three services that speak
   it — and BookBridge's undocumented forward-auth, if it suits better.
3. **After that, not before.** Pangolin public exposure (`newt.nix`), the way
   `guest.zjones.xyz` already works.

⚠ **The order is the point.** Publishing these services with nothing but per-app
logins is precisely the exposure the auth work exists to remove — and BookBridge,
the weakest server here (Flask's development server, running as root, holding
every other service's credentials), would be among the things published. Owner's
decision, 2026-09-15: Pangolin is wired **after** the auth follow-on.

---

## Still open

- **Secrets.** Every value `secrets/galactica.yaml` will need, and ⚠ the
  `nixflix.nix` precedent: *every* secret must exist before sops-nix activates or
  the switch fails.
- **Homepage entries.** `hosts/galactica/homepage/admin/services.yaml`, and
  whether any of it belongs on the guest dashboard. ⚠ `checks/homepage-config`
  fails the build if a widget references an API key its instance's env file does
  not define.
- **Borgmatic wiring** for the two databases — the `mariadb-dump` hook for
  Grimmory (§4.3) and the SQLite treatment for BookBridge (§4.5) — and whether
  they land in `borgmatic.nix` alongside the still-deferred Immich Postgres hook.

### To verify before implementation

These are unknowns that change the design, not preferences. Each wants an answer
in this document.

1. [x] **Does Chaptarr present as Readarr to Prowlarr?** ✅ **Answered
       2026-09-15 — yes, the protocol matches and no enum change is needed** (§5b).
       ⚠ But two open upstream bugs sit on the sync path, so the *sync* is
       unproven: **test it on the host early**, and know that hand-entered
       indexers in Chaptarr are the fallback.
2. [x] **Does Chaptarr hardlink its imports?** ✅ **Answered 2026-09-15** from
       source — it hardlinks when it can and falls back to a size-verified copy
       when it cannot, silently and by design, logging which at Info. §6 carries
       the detail, the ZFS reflink nuance, and the safety argument this turned up.
3. [ ] **Is BookLore's MariaDB volume in `tank/backups/sidepool-pools`?** (§4.4 —
       decides import versus rebuild.)
4. [x] **Does `vpnConfinement` work on an `oci-containers` unit?** ✅ **Answered
       2026-09-15 — no, and silently.** §5a carries the verdict, why Podman is not
       an option here, and the confined-proxy pattern that does work.
       ⚠ Worth proving once on the host so the negative is on record: add
       `vpnConfinement` to a throwaway container, then compare
       `docker exec <c> curl -s ifconfig.me` against
       `ip netns exec wg curl -s ifconfig.me`. The same IP as the host confirms it.
5. [x] **Can Shelfmark disable its IRC source outright?** ✅ **Answered — yes,
       and §5d's bargain holds.** There is no enable flag: the source reports
       itself available only when all four of `IRC_SERVER`/`IRC_CHANNEL`/
       `IRC_NICK`/`IRC_SEARCH_BOT` are non-empty, and searches return nothing
       when it is not. On its own that would only be *unconfigured* — but env
       beats the database and **an empty string counts as set**, so the settings
       save path skips those fields and the UI cannot write over them. Setting
       them empty is therefore a real lock: turning IRC on is an edit to
       `reading-acquisition.nix`.
6. [x] **What database does BookBridge need**, and does it want the same
       pre-snapshot dump treatment as Grimmory's MariaDB? ✅ **Answered
       2026-09-15** — SQLite in WAL mode, and yes: §4.5 carries the shapes that
       are actually restorable, plus the credential-exposure finding that came
       with it.
