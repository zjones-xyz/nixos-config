# galactica — the reading stack

The books/comics/audiobooks half of galactica, complementing the *arr media
stack (`nixflix.nix`, `MANUAL-STEPS.md` §12). Companion to `SHARES.md` (which
shares this inherits and their tiers) and `DECISIONS.md` (why, for anything here
that looks arbitrary).

**Status: spec in progress.** The *client* half — what serves and what reads —
is settled as of 2026-09-15 and is §1–§4 below. The *acquisition* half is
deliberately still open; see "Still open" at the end. Nothing is implemented
yet: there is no `reading.nix`, no secrets, no Traefik routers.

---

## 1. Scope

All four content types are in: **ebooks, comics/manga, audiobooks, podcasts.**

| Service | Owns | Shape | In nixpkgs? |
|---|---|---|---|
| **Grimmory** | ebooks, comics/manga, audiobook files | OCI container + **MariaDB** | ❌ container only |
| **Audiobookshelf** | audiobooks, podcasts | `services.audiobookshelf` | ✅ native module |
| **BookBridge** | read/listen progress sync between the two | OCI container + own DB | ❌ container only |

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

## 2. Why these three

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

## Still open

- **The acquisition half.** What plays Readarr's role, given Readarr's own
  upstream status and that nixflix ships no book module. This is the next spec
  area, and it comes *before* the storage layout because it decides the question
  below.
- **Storage layout.** Whether the library lives inside `tank/nixflix_media`
  (⚠ one dataset, deliberately, so *arr imports can hardlink — `nixflix.nix`'s
  "one layout rule") or gets its own dataset matching its tier. Only relevant if
  acquisition hardlink-imports; if it does, a separate dataset silently turns
  every import into a full copy.
- **Exposure and auth.** Traefik routers (`traefik-galactica.nix`), whether any
  of this is reachable off-LAN, and whether Grimmory's OIDC is wired to anything.
- **Homepage entries.** `hosts/galactica/homepage/admin/services.yaml`, and
  whether any of it belongs on the guest dashboard. ⚠ `checks/homepage-config`
  fails the build if a widget references an API key its instance's env file does
  not define.
