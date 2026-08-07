# Tower — share inventory (current Unraid state)

**What exists today**, read from `/boot/config/shares/*.cfg` on 2026-08-07. This
is the raw starting point for the data classification that `DESIGN.md` §5's
storage layout depends on.

**Classification is in progress** — §5 carries the running verdicts. Three shares
are confirmed dead; the rest of the tiering is still a proposal to argue with.
Sizes are ⟨TBD⟩ pending a `du -sh /mnt/user/*` pass.

**Triage status: 3 of 34 decided.**

Dates are UTC.

---

## 1. Where the data physically lives today

Unraid's `shareUseCache` decides this, and it splits the shares into three groups
with very different migration stories.

| Setting | Meaning | Migration consequence |
|---|---|---|
| `only` | Pool only. **Never touches the array.** | Lives on SSD. Small. Moves independently of the array. |
| `prefer` | Written to pool, mover keeps it there | Same as `only` in practice |
| `yes` | Written to pool, mover moves it **to the array** | Ends up on the array. Part of the 17.1 TB. |
| `no` | Array only, never cached | On the array. Part of the 17.1 TB. |

**Total on the pools is ~285 GB** (Services 240 GB + Fastservices 38.5 GB + Cache
9.31 GB) against ~17.1 TB on the array — so the pool shares are a rounding error
by volume and a large fraction of the shares by count.

---

## 2. The shares

`Sec.` is Unraid's share security; `Write` is `shareWriteList`.
NFS `fsid` values are recorded because **they must be preserved** — see §4.

### Pool-resident (`only` / `prefer`) — never on the array

| Share | Pool | SMB | NFS | Sec. | Write | Comment |
|---|---|---|---|---|---|---|
| `appdata` | services | export | — | private | `z` | Docker application data |
| `arr_config` | services | export | — | public | | *arr stack configuration |
| `appdata_old` | cache *(prefer)* | — | — | private | | "application data" — ⚠ **suspected** leftover, see §3 |
| ~~`ai_models`~~ | fastservices | — | — | public | | 🗑 **DROP** — owner-confirmed dead |
| `arm` | fastservices | export | — | public | | "automatic ripping machine" |
| ~~`jellyfin_cache`~~ | fastservices | — | — | public | | 🗑 **DROP** — owner-confirmed dead. See §3 |
| `swap` | fastservices | — | — | public | | |
| `inbox` | cache | export | — | public | | |

### Array-resident, cached on write (`yes`)

| Share | Pool | SMB | NFS | Sec. | Write | Comment |
|---|---|---|---|---|---|---|
| `arr_media` | cache | export | **fsid 100** | public | | |
| `arr_managed_data` | cache | export | **fsid 102** | public | | Mounted by memory-alpha |
| `jellyfin` | **fastservices** | export | **fsid 101** | public | | Mounted by memory-alpha. ⚠ floor, see §3 |
| `bambuddy_library` | cache | — | **fsid 103** | public | | 3D printing |
| `immich_photos` | cache | export | — | public | | **Photos** |
| `immich_photos_archived` | cache | export | — | private | `z` | **Photos** |
| `books` | cache | export | — | public | | |
| `books_old` | cache | export | — | public | | "top level store for BookLore" — ⚠ **suspected** leftover |
| `calibre_books` | cache | — | — | private | | |
| `copyparty` | cache | export | — | public | | File-sharing service |
| `manyfold_library` | cache | — | — | public | | 3D model library |
| `partdb` | cache | — | — | public | | Parts database |
| `podcasts_audiobookshelf` | cache | — | — | private | | |
| `syncthing` | cache | — | — | private | | |
| `webdav` | cache | — | — | public | | |
| `serenity_time_machine` | cache | export **(TM)** | — | public | | Mac backups, 1 TB volume limit |
| `system` | services | — | — | public | | "system data", split level 1 |

### Array-only (`no`)

| Share | SMB | NFS | Sec. | Write | Comment |
|---|---|---|---|---|---|
| `documents` | export | — | private | `z` | |
| `archived_disks` | export | — | **secure** | `z` | Images of retired disks? ⟨confirm⟩ |
| `ha_backup` | export | — | private | `ha` | Home Assistant backups |
| `music` | export | — | public | | |
| `isos` | export | — | public | | "ISO images" |
| `domains` | — | — | public | | "saved VM instances", split level 1 |
| `public` | export | — | public | | |
| `minishare` | export | — | public | | |
| ~~`SHARE`~~ | — | — | public | | 🗑 **DROP** — owner-confirmed dead |

---

## 3. Three things worth looking at before classifying

### ⚠ `jellyfin`'s cache floor exceeds its pool's capacity

`jellyfin` is set `shareUseCache="yes"` on **fastservices**, with
`shareFloor="500000000"` — 500,000,000 KB ≈ **477 GiB**.

Fastservices is **223.6 GiB total, 186 GiB free.** The floor is more than twice
the entire pool, so the free-space condition can never be satisfied and **writes
to this share should be bypassing the cache and landing directly on the array**.

Two readings, and the config cannot distinguish them:

- **Intentional** — a way to disable caching for one share without changing
  `shareUseCache` to `no`. It works, if opaquely.
- **A typo** — `500000000` for `50000000` (≈47.7 GiB), which would match the
  floor every other cache-backed share uses.

Worth resolving, because it is the only share whose floor exceeds its pool and
because it silently changes where a large media share writes. Every other floor
checks out against its pool's free space.

**A correlation worth noting:** `jellyfin_cache` — the other fastservices share
in Jellyfin's orbit — is **owner-confirmed dead** (below). Two Jellyfin-related
caching artifacts on the same pool, one abandoned and one configured so it can
never engage, is consistent with the caching arrangement having been reworked and
both remnants left in place. That does not settle intentional-versus-typo, but it
makes "leftover from a change" the more likely story than either.

⚠ **Cleaning up dead shares will not fix this.** The floor exceeds fastservices'
*total capacity* (477 GiB against 223.6 GiB), not merely its free space, so no
amount of reclaimed space brings it within reach. It needs the value changed, or
`shareUseCache` set to `no` to say plainly what is already happening.

### ⚠ Stale shares — confirmed by the owner, and the cheapest win available

**Owner's assessment, 2026-08-07: "some of them are well out of date and should
be dropped."** Deleting a dead share before the migration is the best trade on
offer — data you neither copy, nor stage, nor compute parity over, nor carry
forever afterwards. It shortens the initial sync and shrinks the exposure window
at zero risk to anything live.

**Confirmed dead by the owner** — drop these, do not migrate them:

| Share | Lives on | Note |
|---|---|---|
| `jellyfin_cache` | fastservices | See the floor correlation below |
| `ai_models` | fastservices | |
| `SHARE` | array | Also the one that read as an Unraid template |

**Suspected from configuration, not yet confirmed:**

- **`appdata_old`** (`prefer`/cache, "application data") against **`appdata`**
  (`only`/services). The live one is almost certainly `appdata` on the Services
  mirror; `appdata_old` looks like a leftover from the move onto that pool.
- **`books_old`** ("top level store for BookLore") against **`books`**.

**The rest cannot be found in configuration**, because a share that nothing has
written to in three years looks identical to one written yesterday. Two cheap
signals rank them:

```sh
# Newest file per share, oldest shares first. The staleness ranking.
for d in /mnt/user/*/; do
  printf '%s\t%s\n' \
    "$(find "$d" -type f -printf '%TY-%Tm-%Td\n' 2>/dev/null | sort -r | head -1)" \
    "$(basename "$d")"
done | sort

# Size per share, smallest first. Near-empty shares are usually abandoned.
du -sh /mnt/user/* 2>/dev/null | sort -h
```

Cross-reference the bottom of both lists against what is actually running — a
share with an old mtime that a container still reads is *archival*, not dead, and
that distinction is not in the filesystem.

⚠ **`_old` in a name is a hint, not evidence.** Confirm each is genuinely dead
before deleting; the whole point of the exercise is that this data is not coming
back.

### `arr_media` and `arr_managed_data` are separate shares

`DESIGN.md` §4.6 turns on the *arr stack's imports being hardlinks rather than
copies, which requires source and destination on one filesystem, reached through
a single mount of a common parent.

Under Unraid both are directories beneath `/mnt/user`, so a container mounting
`/mnt/user:/data` keeps hardlinks working. Under mergerfs the same discipline
applies, plus a **non-path-preserving create policy** — a path-preserving one
returns `EXDEV` across branches and silently degrades every import to a copy.

⟨Confirm what actually lives in each: which is downloads, which is the library,
and whether the containers mount a common parent today.⟩

---

## 4. NFS exports must keep their `fsid`s

| fsid | Share | Known consumer |
|---|---|---|
| 100 | `arr_media` | ⟨TBD⟩ |
| 101 | `jellyfin` | **memory-alpha** — `/mnt/unmanaged`, feeds `modules/nixos/jellyfin.nix` |
| 102 | `arr_managed_data` | **memory-alpha** — `/mnt/arr_managed_data` |
| 103 | `bambuddy_library` | ⟨TBD⟩ |

NFSv4 uses `fsid` as the export's identity. **Carry these numbers into the NixOS
`exports(5)` file verbatim.** They cost nothing to preserve, and changing them
hands clients `ESTALE` on their next access rather than a clean remount.

memory-alpha's mounts are `soft` + `x-systemd.automount` + `noauto`, so it
degrades rather than hangs while Tower is down — but Jellyfin's library goes
empty for the duration of any migration window. Schedule around it.

---

## 5. Classification — the actual open question

`DESIGN.md` §5 assumes a **two-way** split: irreplaceable data gets real-time
checksummed redundancy (btrfs raid1), re-acquirable data gets snapshot parity
with a 24 h lag. The owner has flagged that there are more categories than two,
and that classifying properly will change the layout.

**Below is a starting proposal to argue with, not a decision.** The `⟨?⟩` marks
are shares whose contents I cannot infer from configuration alone.

| Proposed tier | Shares | Why |
|---|---|---|
| **Irreplaceable** — real-time redundancy + offsite | `immich_photos`, `immich_photos_archived`, `documents`, `archived_disks` ⟨?⟩ | Cannot be re-acquired at any price |
| **Painful to rebuild, small** — redundancy, cheap because tiny | `appdata`, `arr_config`, `system`, `ha_backup` | Service state. Hours of reconfiguration, but gigabytes not terabytes |
| **Re-acquirable** — snapshot parity, 24 h lag fine | `arr_media`, `arr_managed_data`, `jellyfin`, `isos` | The brief's explicit case |
| **Regenerable** — parity optional | `swap`, `domains` ⟨?⟩, `serenity_time_machine` | Reproducible from a source that still exists |
| **Drop** — do not migrate at all | **Confirmed:** `jellyfin_cache`, `ai_models`, `SHARE`. **Suspected:** `appdata_old`, `books_old`. ⟨+ whatever the staleness pass in §3 surfaces⟩ | Dead. Cheapest possible win |
| **⟨?⟩ Needs a decision** | `music`, `books`, `calibre_books`, `podcasts_audiobookshelf`, `manyfold_library`, `bambuddy_library`, `partdb`, `syncthing`, `copyparty`, `webdav`, `public`, `minishare`, `inbox`, `arm` | Could be either — depends on provenance |

**Do the Drop row first.** It is the only tier that makes every other decision
smaller, and it needs no design thinking — just the staleness pass in §3 and a
verdict per share.

**The `⟨?⟩` row is the real work**, and most of it turns on one question per
share: *if this vanished, could I get it back, and at what cost?* `music` is the
archetype — ripped from discs you still own is regenerable; accumulated over
twenty years from sources that no longer exist is irreplaceable, and the config
cannot tell the difference.

`serenity_time_machine` deserves its own thought: it is a *backup*, so losing it
costs nothing while the Mac is healthy, and everything if both fail together.
Whether that pairing is worth protecting against is a judgement, not a fact.
