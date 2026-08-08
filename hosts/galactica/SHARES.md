# Tower — share inventory (current Unraid state)

**What exists today**, read from `/boot/config/shares/*.cfg` on 2026-08-07. This
is the raw starting point for the data classification that `DESIGN.md` §5's
storage layout depends on.

**Classification is in progress** — §5 carries the running verdicts. Three shares
are confirmed dead; the rest of the tiering is still a proposal to argue with.
Sizes are ⟨TBD⟩ pending a `du -sh /mnt/user/*` pass.

**Triage status: 19 of 34 decided** (1 parked — see §5). Three under owner review:
`inbox`, `minishare`, `copyparty`.

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
| `arm` | fastservices | export | — | public | | 🛡 **Protected** — "automatic ripping machine" |
| ~~`jellyfin_cache`~~ | fastservices | — | — | public | | 🗑 **DROP** — owner-confirmed dead. See §3 |
| `swap` | fastservices | — | — | public | | ⚙ **Does not migrate** — Unraid furniture, see §5 |
| `inbox` | cache | export | — | public | | |

### Array-resident, cached on write (`yes`)

| Share | Pool | SMB | NFS | Sec. | Write | Comment |
|---|---|---|---|---|---|---|
| `arr_media` | cache | export | **fsid 100** | public | | |
| `arr_managed_data` | cache | export | **fsid 102** | public | | Mounted by memory-alpha |
| `jellyfin` | **fastservices** | export | **fsid 101** | public | | Mounted by memory-alpha. ⚠ floor, see §3 |
| `bambuddy_library` | cache | — | **fsid 103** | public | | 🛡 **Protected** — 3D printing |
| `immich_photos` | cache | export | — | public | | 💎 **Precious** |
| `immich_photos_archived` | cache | export | — | private | `z` | 💎 **Precious** |
| `books` | cache | export | — | public | | 🛡 **Protected** |
| `books_old` | cache | export | — | public | | "top level store for BookLore" — ⚠ **suspected** leftover |
| `calibre_books` | cache | — | — | private | | ⏸ 🛡 **Protected (parked)** — see §5 |
| `copyparty` | cache | export | — | public | | File-sharing service |
| ~~`manyfold_library`~~ | cache | — | — | public | | 🗑 **DROP** — owner-confirmed dead |
| `partdb` | cache | — | — | public | | 🛡 **Protected** — parts database. ⚠ paired appdata, §5 |
| `podcasts_audiobookshelf` | cache | — | — | private | | ✅ **Re-acquirable** |
| ~~`syncthing`~~ | cache | — | — | private | | 🗑 **DROP** — owner-confirmed junk |
| `webdav` | cache | — | — | public | | 🛡 **Protected** |
| `serenity_time_machine` | cache | export **(TM)** | — | public | | Mac backups, 1 TB volume limit |
| `system` | services | — | — | public | | "system data", split level 1 |

### Array-only (`no`)

| Share | SMB | NFS | Sec. | Write | Comment |
|---|---|---|---|---|---|
| `documents` | export | — | private | `z` | 🔴 **Critical** |
| `archived_disks` | export | — | **secure** | `z` | 🛡 **Protected** — images of retired disks? ⟨confirm⟩ |
| `ha_backup` | export | — | private | `ha` | Home Assistant backups |
| `music` | export | — | public | | 🛡 **Protected** |
| `isos` | export | — | public | | "ISO images" |
| `domains` | — | — | public | | "saved VM instances", split level 1 |
| `public` | export | — | public | | 🛡 **Protected** |
| `minishare` | export | — | public | | |
| ~~`SHARE`~~ | — | — | public | | 🗑 **DROP** — owner-confirmed dead |

---

## 3. Four things worth looking at before classifying

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
| `manyfold_library` | **array** | 3D model library. First drop that reduces the 17.1 TB |
| `syncthing` | **array** | Second drop with array volume behind it |

⚠ **`manyfold_library` is the first confirmed drop with real volume behind it.**
The other three are pool-resident or an empty template; this one is array data, so
it comes straight off the migration payload. Worth a `du -sh` on it specifically
before deleting, purely to know what the win was.

⟨`bambuddy_library` is the other 3D-printing share and is still unclassified —
adjacent tooling, so worth deciding in the same pass rather than separately.⟩

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

### ⚠ `appdata` — the hard one, and the wrong granularity

**Owner's assessment, 2026-08-07: this is the share that will be a bear.** On
Unraid `/mnt/user/appdata/<container>` is the idiomatic place for every container
to squirrel away whatever it likes, with no convention about what belongs there.
Expect databases, caches, logs, downloaded artwork, credentials and junk, side by
side, in per-container subtrees written by whoever wrote each image.

**So `appdata` is the one share where per-share classification is the wrong unit.**
Everything else on this page is homogeneous enough to get a single verdict.
`appdata` is not: Immich's database is irreplaceable, Jellyfin's metadata cache
regenerates itself, and they sit in sibling directories. The real work item is a
per-container pass:

```sh
du -sh /mnt/user/appdata/* | sort -h
```

**Decided: take a full verified copy before touching anything.** Cheap insurance
— the whole Services pool holds 240 GB, so this is not a case where backing up
first costs anything meaningful.

Three things that make the difference between a copy and a *useful* copy:

- ⚠ **Stop the containers first.** Copying a live SQLite or Postgres file yields
  a torn database that restores cleanly and fails later. Services is btrfs, so
  `btrfs subvolume snapshot -r` is an alternative if downtime is unwelcome — but
  that is crash-consistent, not application-consistent, and for 240 GB a straight
  stop-copy-start is simpler and strictly better.
- ⚠ **Preserve ownership, ACLs, xattrs and hardlinks** — `rsync -aHAX`, not
  `cp -r`. Containers run under specific UIDs (Unraid's default is `99:100`), and
  a copy that loses ownership restores into a stack that will not start.
- ⚠ **Verify it, and date it.** "In case I miss something" means opening it months
  later, when a silently truncated backup is worse than none. Check the copy, and
  keep the manifest with it.

**Put the copy somewhere the migration will not touch** — a drawer disk rather
than the array or the Services pool. A backup that shares a failure domain with
the thing it protects is not one, and the specific scenario here is *the migration
itself goes wrong*.

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

`DESIGN.md` §5 was written around a **two-way** split: irreplaceable data gets
real-time checksummed redundancy (btrfs raid1), re-acquirable data gets snapshot
parity with a 24 h lag. That is not enough categories, and the missing one turned
out to be load-bearing.

### The tiers

Ordered by protection, most to least. **Owner-confirmed entries are bold;**
everything else is a proposal to argue with, and `⟨?⟩` marks a share whose
contents cannot be inferred from configuration.

| Tier | Protection | Shares |
|---|---|---|
| **Critical** | Everything below, **plus versioning and a tested restore** | **`documents`** |
| **Precious and Irreplaceable** | Real-time redundancy, checksummed, **+ offsite** | **`immich_photos`**, **`immich_photos_archived`** |
| **Protected** | Parity. No offsite. | **`music`**, **`books`**, **`bambuddy_library`**, **`partdb`**, **`webdav`**, **`public`**, **`arm`**, **`archived_disks`**, ⏸ **`calibre_books`** *(parked)* |
| **Painful to rebuild, small** | Redundancy; cheap because tiny | `appdata`, `arr_config`, `ha_backup` |
| **Re-acquirable** | Snapshot parity, 24 h lag fine | **`podcasts_audiobookshelf`**, `arr_media`, `arr_managed_data`, `jellyfin`, `isos` |
| **Regenerable** | Parity optional | `domains` ⟨?⟩, `serenity_time_machine` |
| ⚙ **Does not migrate** | n/a — no successor concept | **`swap`**, `system` *(proposed)* |
| 🗑 **Drop** | n/a — deleted before migrating | **`jellyfin_cache`**, **`ai_models`**, **`SHARE`**, **`manyfold_library`**, **`syncthing`**; `appdata_old` + `books_old` suspected |
| **⟨?⟩ Undecided** | — | `inbox`, `minishare`, `copyparty` — owner reviewing |

### Critical vs. Precious — consequence against grief

**Owner's framing, 2026-08-07.** *Critical* is "stuff where if I lose it, that's
a huge problem." *Precious and Irreplaceable* is "stuff like photos that would
make me cry if it was lost."

Those are not degrees of the same thing. They are **different kinds of harm**:

- **Critical** is measured in *consequence*. Records, credentials, licences,
  anything with a legal, financial or operational tail. Losing it creates work
  and exposure in the world.
- **Precious** is measured in *grief*. Photos. Nothing breaks, no deadline is
  missed, and you cannot ever get it back.

**The design consequence is recovery time, not durability.** Both tiers want
offsite copies. But Precious can be restored at leisure — a week to pull photos
back from cold storage costs nothing but patience. Critical often has to be
*available*, and losing access at the wrong moment is itself the problem,
independent of whether the bytes still exist somewhere.

So Critical earns two things Precious does not need: **versioning** (a document
corrupted or wrongly edited three months ago must still be recoverable, which a
mirror does not give you) and **a restore you have actually tested**, because the
first time you exercise a critical restore should not be the time you need it.

That is affordable precisely because **Critical is small.** Records and documents
are gigabytes; the whole belt-and-braces treatment costs almost nothing.

### ⚠ The over-classification rule

**Owner's reasoning on `documents`, 2026-08-07:** *"most files in that share
probably aren't actually critical, but I'd rather just have some miscellania come
along for the ride rather than risk critical things being lost."*

Worth stating as a general rule, because it will come up repeatedly:

> **Classify a share at the level its most valuable content warrants.** Do not
> split a share to avoid over-protecting the boring parts.

Sorting is human work, it is error-prone, and the failure mode is asymmetric: a
misfiled critical document is unrecoverable, while a needlessly-protected junk
file costs some bytes. Freeloaders are cheap; misses are not.

⚠ **The rule has a size limit.** It holds while the waste is negligible, which is
true for every small share and false for a multi-terabyte one. Over-protecting a
50 GB `documents` share costs nothing worth counting; over-protecting a 9 TB
media share would mean mirroring and shipping offsite several terabytes of
re-downloadable video. **Over-classify small shares; split large ones.**

That is also why `appdata` still needs its per-container pass (§3) despite being
only 240 GB — there the reason to split is not storage cost but that some of its
contents are stale caches that *should not* be restored, not merely need not be.

### Why "Protected" is the tier that matters

**Owner's definition, 2026-08-07:** *"stuff I would attempt to save in a disaster
once more important things have been saved, but ultimately it's not irreplaceably
precious. It may not be replaceable, but losing it isn't going to make me cry."*

This separates two axes that "irreplaceable" had been conflating: **can I get it
back**, and **how much do I care**. Those are independent. A share can be
genuinely unrecoverable *and* a tolerable loss, and before this tier existed such
data had nowhere to go — it got filed as irreplaceable by default, because the
alternative label said "re-acquirable" and that was simply false.

**The practical consequence is that Protected draws the offsite boundary**, and
offsite is the expensive part of any of this — bandwidth, a storage service, or
disks rotated somewhere else, all of it recurring. Parity is a one-time cost in
disks you mostly already own.

So the ladder resolves to something with real teeth:

| | Survives disk failure | Survives fire, theft, ransomware | Survives a mistake made months ago | Recurring cost |
|---|---|---|---|---|
| **Critical** | yes | yes | **yes — versioned** | yes |
| **Precious** | yes | **yes** | no | yes — this is the tier you pay for |
| **Protected** | yes | no | no | no |
| **Re-acquirable** | yes | no, and it does not matter | no | no |

**The offsite scope is currently three shares** — `documents`, `immich_photos`,
`immich_photos_archived` — against nine in Protected. That is the shape you want:
the tier that costs money every month stayed small while the tier that costs a
one-time slice of parity absorbed most of the inventory.

⚠ **Protected spans both the array and the SSD pools.** `arm` is `only` on
fastservices and never touches the array, while the rest are array-resident. So
Protected is a *policy*, not a place, and `DESIGN.md` §5 has to implement it in
two locations — SnapRAID parity for the array members, and something else
entirely for the pool ones, since SnapRAID does not cover SSD pools.

**Keeping the top two tiers small is the whole point.** Every share that moves from
Precious to Protected is one that stops costing money every month, and the
honest question for each is not "would I be annoyed" but *"would I pay to get
this back?"*

**`music` and `books` are the first two entries, 2026-08-07**, and `music` landed
exactly where the tier was invented to catch it. It had been the standing example
of a share configuration cannot classify — ripped from discs still owned is
Regenerable, twenty years of accumulation from sources that no longer exist is
unrecoverable — and the answer turned out to be neither of the labels that existed
before Protected did.

⟨**`calibre_books` is adjacent to `books` and still undecided.** Same subject
matter, different share, one of them private. Worth deciding together rather than
tripping over the second one later — as with the `books_old` suspected drop, which
is the third member of that group.⟩

`archived_disks` moves back to undecided on the same reasoning. It was proposed
as irreplaceable purely because it is `secure` and owner-writable, which says
something about *access* and nothing about *value*.

### ⚠ Services own data in *two* places — classify both together

Several shares are the bulk half of a service whose configuration and database
live in `appdata`. `partdb` is the clearest case: this share holds attachments
and uploads, while the database that gives them meaning sits under
`/mnt/user/appdata/partdb`. The same shape applies to BookLore (`books`),
Audiobookshelf (`podcasts_audiobookshelf`), Immich (`immich_photos`), and
`copyparty`.

**Restoring one without the other gives you half a service.** For a media library
that is recoverable — the files are still files, and a rescan rebuilds the index.
For something like a parts database it is not: the attachments survive as a heap
of unlabelled files with nothing left to say what any of them belong to.

> **Rule: a service's `appdata` subtree inherits the highest tier of any data
> share it indexes.**

This is the other half of the per-container `appdata` pass in §3, and it gives
that pass its ordering — do the data shares first, then walk `appdata` assigning
each container the tier its data already earned. It also means `appdata` cannot
carry a single tier, which is the point §3 makes from the other direction.

⚠ `appdata` is currently proposed as *Painful to rebuild, small*. Under this rule
it contains at least one Critical-adjacent and one Precious-adjacent subtree, so
that whole-share tier is a placeholder and not a decision.

### ⏸ Parked — provisional classifications, deliberately deferred

**`calibre_books`, 2026-08-07.** The owner's read is *"probably junk — but I
don't want to sort that out right now. Let's just make it protected, and come
back to it later."*

That is a legitimate move and worth naming, because it will recur: **when a share
is probably droppable but confirming it costs more attention than you want to
spend, park it in a safe tier rather than blocking the pass.** It is the
over-classification rule (above) applied to *time* rather than to contents — the
asymmetry is the same, since parking too high wastes some bytes while deciding
hastily can delete something wanted.

⚠ **The risk is that parking becomes permanent by forgetting.** A parked share
looks exactly like a considered one six months later, so the marker has to
survive:

| Share | Parked at | Suspicion | Revisit trigger |
|---|---|---|---|
| `calibre_books` | Protected | Probably junk; overlaps `books` | Before the offsite/backup scope is finalised |

**Rules for parked entries:**

- **Park upward, never downward.** A parked share sits at the highest plausible
  tier, so being wrong costs storage rather than data.
- **Carry the `⏸` marker everywhere the tier appears**, so nothing reads as
  settled that is not.
- **Revisit before anything expensive is sized off it** — offsite scope,
  photo-tier capacity, or the initial sync. Parked entries inflate those numbers
  by construction.

`calibre_books` is also the middle member of the three-share books group —
`books` (Protected), `books_old` (suspected drop) and this one. When any of the
three is revisited, revisit all three; they almost certainly overlap in content.

### Notes on the "gone" tiers

**Two tiers mean gone, and the distinction matters.** *Drop* is data that exists
and is being deleted on purpose — someone has to be sure, and being wrong is
unrecoverable. *Does not migrate* is a share that exists only because Unraid needs
it, where the target platform solves the same problem its own way and there is
nothing to weigh.

- **`swap`** — owner-confirmed. NixOS declares swap in configuration
  (`swapDevices`, or `zramSwap.enable`), not as a share. Tower is already running
  `zram1` at 15.7 G as swap, so the mechanism is in use on the box today.
- **`system`** — *proposed, not confirmed.* Unraid keeps `docker.img` and
  `libvirt.img` here, and the live machine shows both mounted as loopbacks
  (`loop2` → `/var/lib/docker`, `loop3` → `/etc/libvirt`). NixOS uses plain
  directories for both, so the loopback images have no successor. ⟨Confirm
  nothing else was put in this share.⟩

**Do the Drop row first.** It is the tier that makes every other decision smaller,
and it needs no design thinking — just the staleness pass in §3 and a verdict per
share.

`serenity_time_machine` deserves its own thought: it is a *backup*, so losing it
costs nothing while the Mac is healthy, and everything if both fail together.
Whether that pairing is worth protecting against is a judgement, not a fact.

⚠ **`DESIGN.md` §5's layout assumes two tiers and now has eight.** Revisit it once
Protected is populated. Two things there need rework: the photo-tier sizing was
derived from a world where everything unrecoverable had to go in the mirror, and
**nothing in it provides versioning**, which Critical now requires — btrfs raid1
protects against a disk dying, not against a file being wrong for three months.
Snapshots or a versioned offsite target close that, and neither is in the design
yet.
