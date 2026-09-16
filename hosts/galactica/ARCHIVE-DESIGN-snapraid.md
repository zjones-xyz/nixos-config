# ARCHIVE — the SnapRAID + mergerfs storage design (abandoned)

> Extracted verbatim from `DESIGN.md` on 2026-09-05, at the owner's direction.
> This is the storage half of that document — research for a SnapRAID + mergerfs
> array that was **abandoned before anything was built**, in favour of the ZFS
> pool described in `MANUAL-STEPS.md` §9 / `DECISIONS.md` §7 / `HARDWARE-MAP.md` §1.
> `DESIGN.md` keeps the platform argument (bare metal vs VFIO), the hardware
> sections (§2.1–2.2, §4.6–4.8, §5.5, §6.7) and the verdict record.
>
> **Section numbering is preserved**, so citations of the form `DESIGN.md §5.2`
> elsewhere in the repo resolve here; `DESIGN.md` carries a stub at each cut.
> Research date 2026-08-07 — nothing here has been updated since.

---

## 1. Stability and packaging — §§1.1–1.6

### 1.1 SnapRAID upstream

Single author, Andrea Mazzoleni, since 2011. Fifteen years, no bus-factor improvement, but
also no sign of stalling — quite the opposite:

| Version | Date | Substance |
|---|---|---|
| 12.0 | 2021-12 | Parallel disk scanning |
| 12.1–12.4 | 2022-01 … 2025-01 | Build fixes only (glibc 2.36, musl stack, a cosmetic integer overflow, a function-pointer warning) |
| 13.0 | 2025-10 | Thermal protection (`temp_limit`/`temp_sleep`), `probe`, `--stats`, SMART tuning |
| 14.0 | 2026-03 | `.snapraidignore`, `**` globbing, `relocated` file state, `locate`, log tagging for the daemon |
| 14.1 | 2026-03 | **Fixes an include/exclude regression in 14.0 — "highly recommended to update"** |
| 14.2–14.10 | 2026-04 … 2026-08 | Daemon integration, `--gui-threshold-*` safety logic, SMART import fixes, Alpine stack fix |
| 15.0 | WIP | btrfs/ZFS/bcachefs **snapshot integration** (see §4.1 — this matters a lot), AVX-512BW, ARM64 NEON, `--with-smartctl` configure flags "primarily intended for NixOS and other non-FHS systems" |

Source: [`HISTORY`](https://github.com/amadvance/snapraid/blob/master/HISTORY),
[releases](https://github.com/amadvance/snapraid/releases).

Read the 12.x line correctly: it is not abandoned code, it is a branch that was *finished*
for four years. That is a maturity signal, not a rot signal. The 14.0 → 14.1 regression is
a maturity signal in the other direction — a fresh major that broke include/exclude
directives and needed a same-month fix. Do not be first onto a SnapRAID `.0`.

New in 2026 and directly relevant: **[SnapRAID Daemon](https://github.com/amadvance/snapraid-daemon)**,
first-party, with a REST API, job scheduler, web UI, SMART monitoring, and a notification
engine that speaks **ntfy webhooks** — which this fleet already runs (`modules/nixos/ntfy.nix`).
It requires SnapRAID ≥ 14.0. It is **not packaged in nixpkgs** (I checked both the pinned
26.05 tree and the 26.11 tree in the local store: only `pkgs/by-name/sn/snapraid` exists).

### 1.2 mergerfs upstream

Single author (trapexit / Antonio SJ Musumeci). Over a decade old; upstream states it is
production-ready and used by several NAS distributions
([reliability FAQ](https://github.com/trapexit/mergerfs/blob/master/mkdocs/docs/faq/reliability_and_scalability.md)).

Release cadence is lumpy and worth noting honestly: **2.41.1 (2024-11-19) → 2.42.0
(2026-05-08) is an eighteen-month gap** between tagged releases. Master was not idle, but a
user on a distro package sat on 2.41.1 for a year and a half.

- **2.41.0** (2024-11): FUSE **IO passthrough** (near-native read/write on Linux ≥ 6.9),
  IO-priority proxying, `pfrd` as default create policy, auto-page-cache for `mmap`.
- **2.41.1** (2024-11): listxattr size bug, init bug.
- **2.42.0** (2026-05): `lus` (least-used-percentage) policy, lock-management/open-file
  behaviour fixes, and a **credential-model rework** — mergerfs now runs as root more
  generally and requires FUSE `default_permissions`, to make `allow-idmap` and chroot/container
  setups work. That is a behaviour change that will show up as permission differences when
  nixpkgs bumps.

**Known long-standing limitations** (from
[known_issues_bugs.md](https://github.com/trapexit/mergerfs/blob/master/mkdocs/docs/known_issues_bugs.md)),
all documented, none secret:

- **No POSIX/BSD advisory file locking.** Kernel handles locks for apps that all go through
  the mount, but locks do not reach the branches, and NFS-client locking across hosts does
  not work. Keep anything doing serious locking (sqlite databases) off the pool.
- **No reflink / `FICLONE`** — FUSE cannot express it.
- `mmap` requires page caching; on Linux ≥ 6.6 with mergerfs ≥ 2.41 this auto-enables, but
  upstream still says keep app config/databases on a normal filesystem.
- Directory `mtime` is stale by default (`func.getattr=ff`); use `func.getattr=newest`.
- The 2023–2024 **NFS ESTALE/EIO saga** was a mergerfs bug (bad root generation value)
  that took years to isolate. Fixed in 2.40.1. Instructive about how well-trodden the
  NFS-export path is: less than you'd like.

### 1.3 nixpkgs packaging — what you actually get

Read directly from the pinned tree at
`/nix/store/bgp6cqzszs95fdsrjsl6gpy540rjrac9-source`:

| | nixos-26.05 (pinned) | nixos-26.11 (next) | upstream |
|---|---|---|---|
| `snapraid` | **14.4** *(verified by eval against the pinned tree — an earlier draft said 12.4, which was wrong)* | 14.7 | 14.x |
| `mergerfs` | **2.41.1** | 2.42.0 | 2.42.0 |
| `mergerfs-tools` | commit `80d6c95`, 2023-09-12 | same | (low churn) |
| nixpkgs maintainer | `makefu` (both) | same | — |
| `services.snapraid` | present | **byte-identical to 26.05** | — |
| `services.mergerfs` | **does not exist** | **does not exist** | — |
| `snapraid-daemon` | **not packaged** | **not packaged** | — |

Two major SnapRAID versions behind on the pinned channel. That resolves at the 26.11 bump,
which is also when you inherit whatever 14.x brings. Both packages have a single nixpkgs
maintainer.

Also: `pkgs.snapraid` is `wrapProgram`'d with `smartmontools` on `$PATH`, so `snapraid smart`
works on a non-FHS system. Good. Upstream 15.0 is adding `--with-smartctl`/`--with-zfs`
configure flags explicitly for NixOS, which will make this cleaner still.

### 1.4 `services.snapraid` — what it actually configures, and what it gets wrong

Source: `nixos/modules/services/backup/snapraid.nix`. It is 240 lines and I read all of them.

**What it does well.** It renders `/etc/snapraid.conf` from typed options
(`dataDisks`, `parityFiles`, `contentFiles`, `exclude`, `touchBeforeSync`, `extraConfig`),
asserts SnapRAID's two real invariants (≤ 6 parity files; ≥ parity+1 content files), and
creates two `Type=oneshot` units — `snapraid-sync` (default `startAt = "01:00"`, with
`ExecStartPre = snapraid touch`) and `snapraid-scrub` (default `"Mon *-*-* 02:00:00"`,
`-p 8 -o 10`). Both are `Nice=19`, `IOSchedulingPriority=7`, `CPUSchedulingPolicy=batch`,
and genuinely well hardened: `ProtectSystem=strict`, `ProtectHome=read-only`,
`CapabilityBoundingSet=CAP_DAC_OVERRIDE`, `SystemCallFilter=@system-service`, with
`ReadWritePaths` narrowed to exactly the data disks, parity files (comma-split, per
SnapRAID's split-parity syntax) and content-file directories. This is better systemd
hygiene than most hand-rolled setups.

**Four defects you must fix before trusting it.**

1. **No `snapraid diff` guard before `sync`.** `ExecStart` is bare
   `${pkgs.snapraid}/bin/snapraid sync`. If a data disk fails to mount, or a mergerfs
   misconfiguration makes a branch look empty, the 01:00 sync will faithfully rewrite parity
   to reflect the damaged state, and your ability to recover the *previous* state is gone.
   Every mature SnapRAID deployment in the wild — `snapraid-runner`,
   [`snapraid-aio-script`](https://github.com/TophC7/snapraid-aio.nix), SnapRAID Daemon —
   exists primarily to put a deleted/updated **threshold** in front of sync. The NixOS
   module has none. On SnapRAID ≥ 14 there are native `--gui-threshold-*` options; on the
   pinned 14.4 you must wrap it yourself (`snapraid diff` exits **2** when a sync is needed,
   **0** when not, **1** on error; parse the `removed`/`updated` counts and abort above a
   threshold). **This is the highest-priority thing to build.**

2. **The scrub can start on top of a still-running sync.** The module sets
   `unitConfig.After = "snapraid-sync.service"` on the scrub — but `After=` only orders units
   *within a single systemd transaction*. These are two independently-scheduled timers.
   A 01:00 sync on a 12 TB array runs for hours (§2), so the 02:00 Monday scrub will start
   on top of it. Add `Conflicts=` or gate the scrub on the sync not being active, or simply
   move the scrub to a different day.

3. **No notifications, at all.** A failed sync is a red systemd unit and nothing else.
   Wire `onFailure` units to ntfy, and add a periodic `snapraid status` / `snapraid smart`
   reporter. See §3.

4. **Timers are not `Persistent`.** NixOS's `startAt` sets only `timerConfig.OnCalendar`
   (confirmed at `nixos/modules/system/boot/systemd.nix:724`). A sync missed because the box
   was down is skipped, not caught up.

A fifth, cosmetic: `ReadWritePaths` is built as a list containing a nested list (from
`map (s: splitString "," s) parityFiles`). It works only because Nix's `toString` flattens
it with spaces. Fragile, not broken.

### 1.5 mergerfs on NixOS — no module, you write the mount

There is no `services.mergerfs`. The idiom is a `fileSystems` entry:

```nix
fileSystems."/mnt/user" = {
  device = "/mnt/disk1:/mnt/disk2:/mnt/disk3";
  fsType = "fuse.mergerfs";
  options = [ "cache.files=off" "category.create=pfrd" "func.getattr=newest" /* … */ ];
  depends = [ "/mnt/disk1" "/mnt/disk2" "/mnt/disk3" ];   # ← mount ordering
};
```

`depends` is the NixOS-specific piece that keeps mergerfs from mounting before its branches
([NixOS Discourse thread on exactly this setup](https://discourse.nixos.org/t/feedback-and-advice-on-setting-up-mergerfs-snapraid-in-nixos/58290)).
Every safety-critical option is an untyped string in a list. Given the fleet's
one-concern-per-module convention, write `modules/nixos/mergerfs.nix` that takes structured
options and renders the string, with assertions for the non-negotiables
(`branches-mount-timeout-fail`, `minfreespace`, the NFS trio). That is a hundred lines and
it converts a class of silent misconfiguration into an eval-time failure — which is the
same argument the VFIO plan already made for its eval-time invariant assertions.

### 1.6 Behaviour across nixpkgs upgrades

The module is static and tiny; the risk is package version jumps.

- **SnapRAID 14.4 → later 14.x at the 26.11 bump** is a point-release move, not the major-version jump an earlier draft claimed. Content-file format is
  forward-compatible in the read direction, but 14.0 shipped a real include/exclude
  regression. Procedure: read `HISTORY` for the delta, bump, then run `snapraid status` and
  a `snapraid -a check` on one disk before trusting the next sync.
- **mergerfs 2.41.1 → 2.42.0** changes the credential model (root + `default_permissions`).
  Expect to re-verify container UID/GID behaviour after that bump.
- Both are `pkgs.*` derivations, so you can pin either with an overlay if a bump misbehaves —
  which is the fleet's existing escape hatch and does not exist under Unraid at all.

---


---

## 2. Performance — §§2.3–2.7

### 2.3 Sync duration

**Full/initial sync** ≈ (bytes on the largest data disk) ÷ (that disk's average sequential
rate), since all disks stream in parallel and CPU has headroom.

| Data per disk | Time `[estimate]` |
|---|---|
| 6 TB | ~9 h |
| 8 TB | ~12 h |
| 12 TB (full) | **~18.5 h** |

**Sanity check you already have:** whatever an Unraid parity check currently takes on this
machine is a good empirical proxy — both are whole-array sequential passes over the same
disks on the same controllers. If your parity check runs ~20 h, expect a full SnapRAID sync
in the same ballpark. Use your own number, not mine.

**Incremental daily sync.** Only changed files are read. For an *arr workload adding, say,
50–200 GB/day, that is minutes to under an hour of actual work — plus the file-scan phase,
which walks every inode on every data disk (parallel since 12.0) and takes a few minutes on
a few-million-file array `[estimate]`. The practical consequence: **you can afford to sync
much more often than once a day**, which directly shrinks the exposure window in §4.1.
Four to six times a day is entirely reasonable, and I recommend it.

### 2.4 The write-throughput story vs Unraid — the honest version

**SnapRAID computes no parity at write time.** A write to a data disk goes straight to XFS or
btrfs at the disk's native rate. Nothing else spins, nothing is read back.

**Unraid** with dual parity, in default read/modify/write mode, must for each write: read the
old data block, read parity 1, read parity 2, then write data, parity 1, parity 2 —
six operations across three spindles with seeks between them. `[community-reported]`
figures cluster around **50–55 MB/s** to the array
([Unraid forums](https://forums.unraid.net/topic/196614-slow-write-performance-to-array-is-this-typical-or-is-there-a-problem)).
Turbo/reconstruct-write trades that for spinning every disk and lands near disk speed.

So the raw comparison is roughly **50 MB/s vs 180+ MB/s — a 3.5×+ improvement.**

**But be skeptical of that number in context.** Your Unraid install has a cache SSD and a
mover. SABnzbd unpacks and *arr imports land on cache at SSD speed and migrate to the array
overnight. The parity penalty is largely already hidden. The real-world delta for your
workload is therefore *much smaller than 3.5×*, and mostly shows up in (a) bulk operations
that bypass cache, (b) mover windows, and (c) the day you fill the cache. Do not buy this
migration for write speed.

### 2.5 mergerfs overhead, per workload

Upstream's own `dd` benchmark on a tmpfs branch, i7-8809G `[upstream-measured]`
([passthrough.md](https://github.com/trapexit/mergerfs/blob/master/mkdocs/docs/config/passthrough.md)):

| Config | Throughput |
|---|---|
| Straight to tmpfs (native) | 1.7 GB/s |
| `cache.files=off` (direct-io), no passthrough | 800 MB/s |
| `cache.files=auto-full`, `passthrough.io=rw` | 1.6 GB/s (~95% native) |
| `cache.files=auto-full`, no passthrough | 518 MB/s |

This is a *ceiling* measurement on RAM-backed storage. The relevant reading for you: **even
the slowest configuration (518 MB/s) is ~3× faster than a single 12 TB spinner.** Sequential
throughput through mergerfs will not be your limit.

- **Jellyfin streaming:** sequential reads of large files. Untouched. FUSE adds per-request
  latency in the low tens of microseconds against a disk whose seek is ~8 ms. Irrelevant.
  Direct-play and transcode both fine.
- **SABnzbd par2/unrar:** CPU-bound on this Xeon, not I/O-bound. par2 verification of a
  50 GB set is minutes of CPU on 4C/8T. mergerfs is not in the critical path. **Put the
  incomplete/unpack directory on SSD, not on the pool** — that removes mergerfs, SnapRAID
  churn, and spinning-disk random I/O from the hottest path in one move.
- ***arr imports and hardlinks:** work, and are the crux — see §4.5. Performance is fine;
  correctness needs configuration.
- ***arr library scans:** the one place mergerfs genuinely costs. `readdir`/`stat` are
  `O(branches)`. With 3–4 branches, **`[estimate]` 1.5–3× slower than a single filesystem**
  for a full-library rescan. On a 10^5-file library that turns a 2-minute scan into 3–6
  minutes. Mitigate with `cache.readdir=true`, `cache.entry`/`cache.attr` timeouts, and
  `func.readdir=cor` if it helps. Not a blocker; do measure it.
- **NFS re-export:** see §4.6. Functionally fine, needs three specific mergerfs options and
  `fsid=` on the export.

### 2.6 The passthrough.io decision

`passthrough.io` gets you ~95% of native. It also **silently disables `moveonenospc`**
("does not work because errors are not reported back to mergerfs"), plus `nullrw`,
`parallel-direct-writes`, and `cache.writeback`; requires Linux ≥ 6.9 (nixos-26.05 ships
**6.12.64** — verified by `nix eval` on the pinned tree, so this is available); requires
`cache.files` ∈ {partial, full, auto-full}; and requires mergerfs to run as root.

**Recommendation: do not enable it.** Your branches are 180 MB/s spinning disks. The
non-passthrough path already delivers 3× that. You would be trading a real, useful
safety net (`moveonenospc` rescuing an ENOSPC mid-write by relocating the file) for
throughput you cannot use.

### 2.7 Scrub cost

nixpkgs defaults: weekly, `-p 8 -o 10` (8% of the array, skipping blocks scrubbed in the
last 10 days). Full coverage in ~12–13 weeks.

`[estimate]` For a 36 TB data + 12 TB parity array: 8% ≈ 3.8 TB of reads per run; at
~540–700 MB/s aggregate that is **1.5–2 h weekly**. A `-p full` scrub is a whole-array pass,
~19 h.

Two things to fix in the defaults: (a) it will collide with the sync (§1.4 defect 2), and
(b) 12–13 weeks to detect bit rot is a long latency. Consider `-p 15` weekly for ~6-week
coverage, and see §4.3 for why btrfs on the data disks makes this much less important.

---


---

## 4. Failure modes — §§4.1–4.5

### 4.1 What "parity is 24 hours stale" actually costs

Three categories, and the third is the one almost everyone misses.

**(a) Files *created* on the failed disk since the last sync — unrecoverable.** Obvious and
expected. For an *arr workload: yesterday's grabs.

**(b) Files *modified* on the failed disk since the last sync — recovered to their
pre-sync content.** Fine for media (immutable once written).

**(c) Files *deleted or modified on the SURVIVING disks* since the last sync can prevent
recovery of files on the FAILED disk.** Upstream, verbatim
([manual §3](https://github.com/amadvance/snapraid/blob/master/doc/snapraid.txt)):

> Without snapshot support, deleting or changing files after a `sync` can prevent the full
> recovery of other failed disks. This occurs because the parity no longer matches the
> modified files, **even if those files are not on the failed disk.**

The mechanism: parity block *i* is a function of block *i* on **every** data disk. To
reconstruct the failed disk's block *i* you need the current parity plus the *same* data
from every survivor that the parity was computed from. Change a survivor's block *i* and the
equation no longer balances.

**Why this matters specifically for you:** the damage is *not* proportional to how much
changed on the failed disk. It is proportional to churn across the **whole array**. And an
*arr stack churns continuously — quality upgrades delete the old file and write a new one,
all day, on whichever disks the mergerfs policy put them on. That is precisely the pattern
this failure mode punishes. Unraid has no equivalent exposure: its parity is always current.

**Mitigations, in order of usefulness:**

1. **Sync far more often than daily.** Incremental syncs are cheap (§2.3). At 4–6× a day the
   window is 4–6 hours instead of 24. This costs you nothing and is the single best fix.
   The nixpkgs module supports it directly — `sync.interval = "*-*-* 00,04,08,12,16,20:00:00"`.
2. **`snapraid fix --import DIR`** can pull deleted files back into the recovery if you still
   have them somewhere (e.g. a trash directory). Worth setting up `mergerfs.mktrash`.
3. **btrfs snapshots on the data disks, taken immediately before each sync, with SnapRAID
   pointed at the snapshots.** This eliminates category (c) entirely. Third-party today
   ([`btrfssnapraid`](https://github.com/dim-geo/btrfssnapraid) `[unverified — I did not
   evaluate its quality]`), first-party in **SnapRAID 15.0**, which is WIP and explicitly
   says snapshots "significantly improve recovery success by preserving access to files that
   were updated or deleted after the last parity computation". **This is the strongest
   forward-looking argument for putting btrfs on the data disks now.**

### 4.2 Restore procedure and realistic restore time

Procedure (manual §4.4): stop all writes and all scheduled jobs → edit `snapraid.conf` to
point the failed disk's `data` line at the replacement → `snapraid -d dN -l fix.log fix` →
optionally `snapraid -d dN -a check` → `snapraid sync`. Unrecoverable files are renamed with
a `.unrecoverable` suffix and enumerated in `fix.log`. **You can re-run `fix` as many times
as you like — but once you `sync`, you cannot.**

**Time `[estimate]`:** `fix` reads every surviving data disk and all parity in parallel and
writes the replacement. Bound by the write to the replacement: 12 TB ÷ ~180 MB/s =
**~18.5 h floor**. `[community-reported]` `fix` runs noticeably slower than `sync`
(one SourceForge thread is literally titled ["Fix speed ~4x slower than sync"](https://sourceforge.net/p/snapraid/discussion/1677233/thread/2408c31a85/)).
**Plan for 24–40 hours**, plus an optional `check` pass of similar length.

Comparable to an Unraid rebuild on the same hardware, so not a differentiator on wall time.
The differentiator is **posture**: Unraid rebuilds with the array online and writable.
SnapRAID's manual opens the recovery chapter with *"avoid further changes to your disk array.
Disable any remote connections to it and any scheduled processes"*. In practice the surviving
mergerfs branches remain readable throughout — Jellyfin keeps streaming what is on the live
disks — but you must stop *writes*, meaning the *arr stack and SABnzbd are down for a day or
two. Budget that.

**Two SnapRAID-specific gotchas nobody mentions until it bites:**

- **Permissions and ownership are not stored.** Upstream, verbatim: *"Only file names,
  timestamps, symlinks, and hardlinks are saved. Permissions, ownership, and extended
  attributes are not saved."* A restored 12 TB media disk comes back with correct content,
  names, times and hardlinks — and **whatever uid/gid/mode the `fix` process created**. For a
  Docker/*arr setup with a specific uid:gid this means a post-restore `chown -R`. Trivial,
  but only if you know in advance. Record the expected ownership in the module's comments.
- **Interrupted syncs weaken recovery.** SnapRAID 15.0's changelog admits the pre-15.0 sync
  optimisation (skipping parity recomputation when input data matches the expected hash)
  *"preserves hash data … to ensure a better fix during disk failures"* only once removed —
  i.e. on 14.x, a sync interrupted by a power cut leaves a window where a subsequent
  disk failure recovers worse than you would predict. Argues for a UPS (§4.7) and for
  `autosave`.

### 4.3 Silent corruption and bit rot — a fair three-way comparison

| | Detection | Attribution | Repair | Latency |
|---|---|---|---|---|
| **btrfs / ZFS** | Checksum verified on **every read** | Exact | Automatic, if redundant | **Zero** — caught at the moment of access |
| **SnapRAID scrub** | 128-bit SpookyHash per 256 KiB block, compared during scrub | Exact — knows *which* block on *which* disk | `snapraid -e fix` from parity | Up to a full scrub cycle (**~12 weeks** at nixpkgs defaults) |
| **Unraid parity check** | Parity mismatch only | **None** — cannot tell which disk is wrong | A "correcting" check rewrites *parity* to match possibly-corrupt data | Whenever you run it |

**SnapRAID is meaningfully better than Unraid here**, and this is an underrated part of the
case. Unraid's parity check tells you something is inconsistent and cannot tell you what;
SnapRAID's hash database tells you exactly which block on which disk went bad and repairs it.

**But SnapRAID's scrub is strictly weaker than btrfs/ZFS in three ways:**

1. It is **periodic**, not read-time. Jellyfin streaming a file reads it straight through
   mergerfs from the underlying filesystem with **no verification at all**. A corrupt block
   plays as a glitch and you learn about it weeks later, if ever.
2. Files **added or changed since the last sync have no hash yet** and are unprotected.
3. Coverage latency of ~12 weeks at defaults.

**Therefore: format the data disks btrfs, not XFS.** You then get read-time detection from
btrfs *and* repair from SnapRAID parity — a combination strictly better than either alone,
and better than anything Unraid offers. It also sets you up for SnapRAID 15.0's snapshot
integration (§4.1). Costs: btrfs's CoW fragments large sequential files less than people
fear for write-once media, but **put the parity files on XFS or ext4, or set `chattr +C`
(nodatacow) on them** — a 12 TB append-and-rewrite file on CoW btrfs will fragment badly.
(SnapRAID 11.2 had to change its `fallocate()` usage specifically to behave with btrfs
parity disks.)

### 4.4 Two disks failing

| Scenario | Single parity (3 data + 1 parity) | Double parity (2 data + 2 parity) |
|---|---|---|
| 1 data disk dies | Fully recoverable (modulo §4.1) | Fully recoverable |
| Parity disk dies | No data loss; re-create parity | No data loss |
| **2 data disks die** | **Both lost — 24 of 36 TB.** The third disk is fully intact and readable. | Both recoverable |
| 1 data + 1 parity die | Data disk lost | Recoverable |

Two properties worth stating explicitly because they are genuinely good and both Unraid and
SnapRAID have them while striped RAID/RAIDZ does not:

- **Damage is confined.** Exceed your parity count and you lose *only the failed disks*.
  Every surviving disk remains a mountable filesystem full of readable files. In a RAID5/6 or
  RAIDZ pool the same event loses everything.
- **Failure is not correlated by rebuild stress** the way RAID5 is, because there is no
  parallel full-array read under a rebuild deadline — though `fix` does read every disk.

The realistic double-failure scenario is *"a second disk dies during the 24–40 h rebuild"*.
For re-acquirable media, that scenario's cost is "re-download more" rather than "lose
something". Which is exactly why double parity on media is the wrong purchase.

### 4.5 mergerfs failure modes

**1. A branch disappears while mounted — the #1 footgun.** mergerfs does not require branch
paths to be mount points; upstream explicitly frames that as a feature. The consequence: if
a disk drops and its filesystem unmounts, `/mnt/disk2` becomes an empty directory **on the
120 GB root SSD**, and mergerfs will cheerfully start writing new files into it. You fill
root, you put files somewhere SnapRAID is not looking, and `snapraid diff` reports a
catastrophic number of "removed" files — which the nixpkgs module's unguarded 01:00 sync
will then dutifully bake into parity (§1.4 defect 1). **The two bugs compound.** Mandatory
mitigations:

- `branches-mount-timeout=<seconds>` **and `branches-mount-timeout-fail=true`** so mergerfs
  refuses to run rather than run wrong;
- mark the bare mountpoint directories with the `user.mergerfs.branch_mounts_here` xattr
  (and `user.mergerfs.branch` on the mounted filesystem roots) so mergerfs can tell mounted
  from not;
- `chown root:root` + `chmod 0000` on the mountpoint directories before mounting;
- `x-systemd.mount-timeout` longer than `branches-mount-timeout`;
- plus the `diff` threshold guard on sync as the backstop.

**2. A branch stops responding without unmounting.** *"If the underlying filesystem freezes up
or blocks then the thread issuing the request will block… If enough threads block then
mergerfs will block. There are no timeouts or ways to truly work around this situation."*
A dying disk that hangs on I/O can wedge the entire pool, and therefore Jellyfin, the *arr
stack, and the NFS export to memory-alpha. This is a genuine regression versus Unraid, which
disables a failing disk and serves it emulated from parity. **There is no fix; know it.**

**3. Split brain across branches.** The same relative path on two branches with different
content. `func.getattr` (default `ff`, first-found) picks what you see; the other copy is
invisible but consumes space and confuses SnapRAID. Causes: writing to branches directly
instead of through the pool, or a policy change mid-life. Use `func.getattr=newest`, never
write to branches out of band, and run `mergerfs.dedup` (nixpkgs pins a 2023 commit)
periodically.

**4. Hardlinks — critical for *arr, and they do work.** Upstream: *"Yes. links are
fundamentally supported by mergerfs… All comments elsewhere claiming they do not work are
related to the setup of the user's system."* Two traps:

- **Container bind mounts.** Mounting `/mnt/user/downloads` and `/mnt/user/media` as
  *separate* volumes into a container makes them different devices to the kernel → `EXDEV`
  → Sonarr/Radarr fall back to copy-then-delete. **Mount the common parent once** (e.g.
  `/mnt/user:/data`) and use paths beneath it. This is the exact same constraint that
  the VFIO plan already encoded ("they share one `/data` root so imports are hardlinks and
  moves are atomic"), so the discipline already exists — see `DECISIONS.md`, *Carried
  forward*.
- **Create policy.** *Path-preserving* policies (`epmfs`, `epff`, `eplfs`, `eplus`) return
  `EXDEV` when source and target directories live on different branches — by design, since
  honouring the link would violate the policy. **Non-path-preserving policies (`pfrd` — the
  default since 2.41.0 — or `mfs`) clone the target directory path onto the source branch and
  complete the link.** Use `pfrd`.
  The trade: `pfrd` scatters a series across disks (worse failure locality, more spin-ups);
  `epmfs` keeps a show on one disk but breaks hardlinks. For an *arr stack, **hardlinks win**.

**5. `moveonenospc`.** When a write hits `ENOSPC`/`EDQUOT` on a nearly-full branch, mergerfs
relocates the file to another branch and retries. Enable it. Note it is **silently disabled by
`passthrough.io`** — see §2.6. Note also it applies only to `write()`, never to `create()`:
if the create policy itself returns ENOSPC you get the error.

**6. `minfreespace` misconfiguration.** Set it comfortably above your largest single file
(100–250 GB for 4K remuxes). Too low and you get ENOSPC on a pool that reports terabytes
free. Also: mergerfs uses *available* space for `statfs`, so ext4's root reserve makes the
pool look smaller than it is — irrelevant if you use btrfs/XFS.

**7. No advisory file locking, and `mmap` caveats.** Both documented (§1.2). Practical rule:
**every container's config directory and every sqlite database lives on SSD, never on the
pool.** You would do this anyway for performance; now it is also a correctness requirement.


---

## 5. Storage layout — §§5.1–5.4

### 5.1 The structural constraint, restated

SnapRAID parity is array-wide. You cannot mix parity levels within one array. Parity disks
must each be ≥ the largest data disk. With four 12 TB disks:

| Layout | Usable | Photos protection | Media protection | Verdict |
|---|---|---|---|---|
| **A.** 2 parity + 2 data, one array | 24 TB | Double parity (stale) | Double parity (overkill) | Meets the letter of the brief. Costs 50% of capacity to over-protect re-acquirable media. Status quo. |
| **B.** 1 parity + 3 data, one array | 36 TB | Single parity — **violates req. 1** | Single parity | Only viable if photos leave the array. |
| **C.** Two SnapRAID arrays on disjoint disks | — | 2 parity + 1 data = **3 disks** | 1 disk left | **Infeasible.** Photos are a "small minority" and this spends 75% of the array on them. |
| **D.** Photos on btrfs raid1 SSDs; media = 1 parity + 3 data | 36 TB media + ~480 GB photos | **Better than double parity** — see below | Single parity | **Recommended.** |
| **E.** Photos on btrfs raid1 SSDs; media = 4 data, **no parity** | 48 TB media | Same as D | None | Defensible. See §5.3. |

**C is the option the brief invites and it does not survive contact with the disk count.**
Two independent arrays need six 12 TB disks to do this properly (2p+1d and 1p+2d). You have
four.

### 5.2 Why moving photos off the array is better, not just cheaper

Requirement 1 asks for double parity on irreplaceable data. **Double SnapRAID parity is not
what irreplaceable data wants**, for three concrete reasons:

1. **It is up to 24 h stale.** New photos — the ones you just imported off a camera and have
   not backed up anywhere — are exactly the photos SnapRAID cannot recover.
2. **§4.1(c) applies.** Churn on surviving disks, driven by an *arr stack that has nothing to
   do with photos, can block recovery of photos on a failed disk. Sharing an array with a
   high-churn workload actively degrades the protection of the low-churn workload.
3. **Parity is not backup.** SnapRAID's own manual: *"SnapRAID can recover data only from a
   limited number of disk failures. With a backup, you can recover from a complete failure of
   the entire disk array."* Parity protects against nothing else — not fire, not theft, not
   `rm -rf`, not ransomware, not filesystem corruption that propagates before the next scrub.

**Recommendation for photos: btrfs raid1 across the 2× Crucial BX500 480 GB, plus a real
offsite backup** (restic/rclone to a cloud target, or seeded to another fleet host). That
gives you:

- checksums verified on **every read**, with automatic repair from the mirror — strictly
  stronger than any parity scheme;
- **real-time** redundancy, no staleness window;
- complete isolation from *arr churn;
- SSD-speed access;
- and the backup that actually addresses "irreplaceable".

The MX100 512 GB becomes a third local copy via `btrfs send`/`receive` snapshots — the fleet
already has `modules/nixos/btrfs-snapshots.nix` to build on.

**Hard prerequisite: photos must fit in ~450 GB usable.** You said they are a small minority
of total data, which is consistent, but **`[unverified]` — measure it before committing.**
If photos exceed ~450 GB, fall back to a btrfs raid1 pair of 12 TB disks and run media on
the remaining two as 1 parity + 1 data (12 TB) — which is a much worse trade, and at that
point option A (status quo) becomes competitive again.

### 5.3 Does *arr media warrant any parity? The honest answer.

You asked for plainness, so: **yes, one parity disk, and no more.** Reasoning, both sides.

**The case for zero parity (option E):**
- The data is re-acquirable by definition.
- It buys 12 TB (48 TB vs 36 TB usable).
- It removes the sync, the scrub, and the entire §4.1 failure-mode class from your life.
- With btrfs per disk you keep corruption *detection*; you just cannot repair.

**The case for one parity (option D), which I find stronger:**
- Re-acquiring ~12 TB is a genuinely miserable multi-week project: ~90+ hours of download at
  300 Mbit/s, plus usenet retention gaps on older content, plus indexer/API rate limits, plus
  manual triage of everything that did not come back. It is not "press a button".
- 12 TB of 48 TB is a 25% tax — and you are *currently* paying a 50% tax. Option D is still
  a **50% capacity increase over today** (24 TB → 36 TB).
- SnapRAID's hash database over the media is worth having on its own, and **SnapRAID requires
  at least one parity disk to exist at all** — there is no hash-only mode. Zero parity means
  no SnapRAID, which means no block-level integrity database over 36–48 TB of media.
- The marginal cost of the nightly sync is small once you have built the tooling anyway for
  the photos... no, actually you would not build it at all under option E. That is the one
  real argument for E: it deletes the most operationally demanding component of the design.

**Where E wins:** if after building this you find the sync/scrub/alerting apparatus is more
maintenance than it is worth, dropping to zero parity is a **one-line config change and a
disk reformat**. Keep that in your pocket. It is not a decision you have to get right now.

**Double parity on media is not defensible under any reading of your requirements.**

### 5.4 The capacity result — and an honesty check

| | Today (Unraid) | Recommended (option D) |
|---|---|---|
| Media usable | 24 TB | **36 TB** |
| Media parity | 2 (real-time) | 1 (≤6 h stale, if you sync 4×/day) |
| Photos | On the array, double parity, stale | btrfs raid1 SSD, checksummed, real-time, + offsite |
| Media integrity | Parity check, no attribution | btrfs read-time checksums + SnapRAID hashes + repair |

**The honesty check: the 50% capacity gain comes from the parity-level decision, not from
SnapRAID.** Unraid supports 1 parity + 3 data perfectly well, and Unraid pools support btrfs
raid1 for the photos. **You could have every row of that table tomorrow without leaving
Unraid.** If capacity and photo protection are what you actually want, the storage-layout
change is the whole win and the platform change is separate. Do not let the two get
conflated — and consider doing the layout change *first*, under Unraid, because it de-risks
the migration enormously (§6).

---


---

## 6. Migration — §§6.1–6.6

### 6.1 The key realisation: this is mostly not a data migration

Unraid does not stripe. Every data disk is a **standalone XFS or btrfs filesystem holding
ordinary files**, mountable by any Linux box; the MD/parity layer sits above and the shares
are aggregated on top ([Unraid data-recovery docs](https://docs.unraid.net/unraid-os/troubleshooting/common-issues/data-recovery/)).
SnapRAID + mergerfs want **exactly that**: whole independent filesystems, plain files,
pooled at a layer above.

**So the primary path is in-place conversion with zero data copying.** The 12 TB staging
constraint is largely irrelevant.

Two things to verify on the machine before committing `[unverified]`:

- ~~**Are the four array disks LUKS-encrypted?**~~ ✅ **Answered 2026-08-07**
  (`HARDWARE-MAP.md` §2): the two data disks and the SSD pools are LUKS; **the two parity
  disks are not, because under Unraid they cannot be.** Unraid's array encryption is plain
  LUKS per disk, so `cryptsetup open` works from NixOS — you need the passphrase and
  `/etc/crypttab` entries, and it changes the boot sequence. ⚠ The parity asymmetry does
  **not** carry over; see step 12.
- ~~**Partition layout.**~~ ✅ **Substantially answered 2026-08-31** via a live
  NixOS boot test (`hosts/galactica/live-iso.nix`, `HARDWARE-MAP.md`'s new
  `sidepool` section): a `cryptsetup luksOpen` + read-only mount of an
  Unraid-built, multi-device LUKS+btrfs pool worked cleanly and completely
  from a bare Linux live environment, no Unraid involved — `btrfs filesystem
  show` reported all members present, nothing missing. That's a harder case
  than the main array's two *single-disk* data disks, which were identified
  by serial (`8CG7T97E` = Disk 1, `8DJPNS3Y` = Disk 2) but not yet
  mount-tested themselves — a quick follow-up, not a real unknown anymore.

### 6.2 Recommended sequence

> **Reordered 2026-08-08.** This section originally assumed you migrate and then
> arrange backups. That is backwards now that the offsite path is fully specified
> (borgmatic → BorgBase, 950 GB — `docs/BACKUP.md`). **Backups first, under
> Unraid, because that is what makes the migration's one dangerous window
> survivable** (§6.3). Three steps below were also simply stale; they are marked.

**Phase 0 — under Unraid, reversible, and it is the phase that matters most.**

1. Back up off-box: *arr databases, Jellyfin config, Docker compose (`homelab-stacks/`),
   Unraid share/user config, LUKS headers (`cryptsetup luksHeaderBackup`). Small, cheap,
   valuable. ⚠ The LUKS headers are the unrecoverable one — without them the disks are
   noise, and no later step restores them.
2. **Stand up borgmatic → BorgBase and get the Precious tier offsite, from Unraid.**
   borgmatic runs as a container today; nothing here waits on NixOS, on the layout
   decision, or on any disk moving. ✅ Container image confirmed:
   `ghcr.io/borgmatic-collective/borgmatic:2.1.5`, pinned to match the borgmatic
   version these configs were validated against (`homelab_stacks`'
   `tower/borgmatic/compose.yaml`).
   Scope: `documents`, `immich_photos`, `immich_photos_archived`, plus Immich's
   database via borgmatic's native hook.
3. **Run the pilot (§6.6) before trusting step 2.** A backup that has never been
   restored is a belief.
4. ~~Create a btrfs raid1 pool of the 2× BX500 and move photos onto it.~~
   ⚠ **Superseded by §5.5.** Photos go to a **4 TB pair**, not the SSDs — which
   dissolved the "do photos fit in 450 GB?" assumption entirely. The BX500 pair
   became the app-state tier. This step is *blocked* on the CMR question (§6.7)
   and is no longer urgent, because step 2 already protects the photos.

**Once step 2 is verified, every later step risks re-acquirable data only.** That is
the whole point of the reordering, and it is worth doing even if you abandon the rest.

**Phase 1 — free a disk at zero risk.**

4. In Unraid: stop array, **unassign parity 2**, start array. Dual → single parity is a
   supported, data-safe operation
   ([Unraid forums, repeatedly](https://forums.unraid.net/topic/98267-downgrading-from-dual-to-single-parity/)).
   You now hold a **completely free 12 TB disk** and the array is still parity-protected.
   Since the target design uses single parity for media anyway, this is a step you take
   regardless.
5. Run one last parity check + a `xfs_repair -n` / `btrfs check --readonly` on each data disk.
   Migrate a healthy array, not a sick one.

**Phase 2 — install NixOS alongside, non-destructively.**

6. Install NixOS on the root disk (§5.5 — the 1 TB NVMe; the Kingston is retired). **The Unraid flash
   stays plugged in and bootable.** You can boot either. Note: once you write to the Unraid
   data disks from NixOS, Unraid's parity is stale — falling back then means a parity rebuild
   (~20 h), not data loss. That is an acceptable fallback and worth writing down.
7. ⚠ **Not a re-lay — the array cabling is already right.** `HARDWARE-MAP.md` §4
   measured the actual port map and found both SSDs already on the 6 Gb/s ports and
   all four spinners on the 3 Gb/s ports, which *is* the bare-metal optimum. What
   remains is additive: NVMe on its adapter, BD-ROM out to USB, photo and scratch
   disks onto whatever card wins §6.7, and **remove the ASM1064**.
8. Bring up the host config with **no storage**: hostname/DNS, bond, sops, Tailscale, NUT
   server, ntfy, Traefik, and a **Beszel agent** (`modules/nixos/beszel.nix` — the hub
   already runs on hopper). Prove the fleet plumbing before touching disks.
   ⚠ Dockge is deliberately *not* in this list any more — see §6.5.

**Phase 3 — the pivot.**

9. Boot NixOS. Mount the existing Unraid data disks **read-only** by UUID at
   `/mnt/disk1`, `/mnt/disk2`. Verify you can read everything.
10. Format the freed 12 TB disk (from step 4) as `/mnt/disk3` — **btrfs** (§4.3).
11. Remount disk1/disk2 read-write. Build the mergerfs pool at **`/mnt/user`** over
    disk1:disk2:disk3, with the mountpoint safety options from §4.5.
12. Format the remaining Unraid parity disk as the **SnapRAID parity disk**. XFS or
    ext4 (or btrfs + `chattr +C` set on the *directory* before the parity file exists —
    the flag only takes on a file with no data blocks). ⚠ **LUKS it.** Under Unraid the
    parity disk holds combinations of ciphertext and is legitimately unencrypted;
    SnapRAID parities *plaintext files*, and parity of known plaintext is recoverable
    plaintext (§5.5). This is silent and easy to miss precisely because the disk it
    replaces was fine unencrypted.
13. `snapraid sync` — the initial parity build, **~12–18 h** (§2.3).
14. Bring up NFS exports (§4.6), then the Docker stacks. Verify memory-alpha's two mounts
    and hardlink behaviour inside the *arr containers before declaring done.

**Total elapsed: roughly 1–2 days, dominated by the initial sync. Data copied: zero.**

### 6.3 Exposure windows, step by step

| Step | Redundancy state | Exposure |
|---|---|---|
| 0–3 | Full Unraid single parity | None. Photos improve. |
| 4–5 | Unraid **single** parity | Reduced from double. A single disk failure is still fully recoverable. |
| 6–8 | Unraid single parity (array idle) | None new. Unraid remains bootable. |
| 9 | Read-only mounts | None. |
| **11–13** | **NONE** | **The real window.** From the first write under NixOS until `snapraid sync` completes: **~12–24 h with no parity of any kind.** A disk failure here loses that disk's contents. |
| 14+ | SnapRAID single parity | Steady state. |

**Shrinking the exposure window.** The only genuinely at-risk window is 11–13, and it is
unavoidable in any in-place conversion — you cannot have valid parity for a layout that does
not exist yet. Four mitigations, the first of which is new and is worth more than the other
three combined:

- ⭐ **Get the Precious tier offsite first (Phase 0 step 2).** This does not shrink the
  window; it **changes what the window can cost.** With photos and `documents` already in
  BorgBase, a disk failure between steps 11 and 13 threatens *re-acquirable media only* —
  it stops being "lose the irreplaceable thing" and becomes "re-download, or pull it off
  the parachute." Everything below is about reducing probability; this one caps the
  damage, which is the stronger move. **It is also the only mitigation you can complete
  before deciding anything else about the layout.**

The original three, still valid:

- **Do it in the right order.** Build parity (step 13) *before* migrating Docker workloads
  and re-enabling writes (step 14). The window is then read-mostly.
- **Winnow first.** Requirement 2 says the media is re-acquirable — so delete aggressively
  before migrating. Less data means a shorter initial sync means a shorter window, and it is
  free. This is the honest use of the "re-acquirable" property: not as a reason to skip
  parity, but as a reason to carry less.
- **The parachute is 2.1 TiB and lives on another machine.**

  > **Rewritten 2026-08-08 from measurement.** Every earlier version of this bullet
  > sized the parachute against the whole array and then argued about whether ~18 TB
  > of drawer disks covered 17.1 TB. **That argument is retired rather than
  > resolved — the question was wrong.** The owner's decision to accept the window
  > for *arr* media (`DECISIONS.md` §8) means media does not need covering, and
  > per-share measurement put everything that *does* at 2.4 TiB all-in.

  The window does not discriminate by share, so what needs a parachute is what is
  **array-resident, not re-acquirable, and has no offsite copy** — which is exactly
  the Protected tier. Measured on Tower 2026-08-08:

  | | Size | Covered by |
  |---|---|---|
  | **Protected, array-resident** | **2.1 TiB** | **the parachute** |
  | Critical + Precious, all-in | 215.6 GiB | Phase 0 step 2, offsite |
  | `appdata` | 76.1 GiB | pool-resident — not exposed at all |

  **Target: pegasus's `h-XDAS`** — a 3 TB Toshiba, empty, 2.34 TiB usable on its
  btrfs partition (`hosts/pegasus/HARDWARE-MAP.md`). That is ~10% headroom, and a
  400 GB exfat partition is reclaimable if more is wanted. Copy before step 11,
  keep until step 13 completes.

  **Off-box is better than in-Tower, not merely equivalent.** A parachute on
  pegasus survives a PSU or controller failure rather than only a single-disk
  failure, and it costs **zero Tower SATA ports** — which matters against §5.5's
  budget, where staging disks would otherwise have collided with the step-7
  ASM1064 removal.

  ⚠ **LUKS it first.** `h-XDAS` is unencrypted. Tower's data disks are LUKS, so
  copying the Protected tier onto bare btrfs strips 2.1 TiB back to plaintext at
  rest on a machine in another room. Same shape as the parity-disk trap in §5.5.
  Free now, while the partition is empty.

  ✅ **Health-verified 2026-08-10** — this used to read *"it has never been
  health-tested"*, and it was the single point of failure for the whole Protected
  tier during the window. Both readings now pass: passive attributes clean (0
  reallocated, 0 pending, 0 CRC, `PASSED`) **and** a full 366-minute extended
  surface scan `Completed without error` with no first-error LBA. Details in
  `hosts/pegasus/HARDWARE-MAP.md` §1.

  ⭐ **The scan is the part that counts**, and it is worth knowing why for the
  other disks in this plan. `h-XDAS` was empty, so its passive counters described
  a platter nothing had read in years — clean-because-healthy and
  clean-because-untouched look identical. Only the surface scan distinguishes
  them. `DISK-DRAWER.md`'s rule — *an untested spare is a guess* — is satisfied by
  the long test, not by `smartctl -a`.

  ⚠ **Health was never the only gate.** `sdb1` is still plaintext; see the LUKS
  warning above, which is now the one thing left before this disk can take the
  role.

  **⭐ Revised 2026-08-10 — pegasus is 2.5 GbE, so this is now disk-bound.** The
  NIC was read as an RTL8125 (`hosts/pegasus/HARDWARE-MAP.md` §4), not the 1 GbE
  part its DMI table claims. That moves the bottleneck off the network and onto
  the receiving spindle:

  | Link | Net ceiling | `h-XDAS` sequential | Binds on | 2.1 TiB |
  |---|---|---|---|---|
  | 1 GbE | ~118 MB/s | ~150–190 MB/s | network | 5–6 h *(the old figure)* |
  | **2.5 GbE** | ~310 MB/s | ~150–190 MB/s | **the disk** | **~3.5–4.5 h** |

  ⚠ **A third off, not half.** `h-XDAS` is a 2012-era 7200 rpm drive and will
  trend to the low end as it fills inner tracks. Past 2.5 GbE a faster link buys
  nothing here — worth knowing before anyone spends on the network for this copy.

  ⚠ **2.5 GbE is the controller, not the negotiated link** — into a gigabit switch
  it runs at 1000 and the old 5–6 h stands. `cat /sys/class/net/enp42s0/speed` on
  pegasus settles it; unread as of 2026-08-10.

  It must finish before step 11. A scheduling input, not a blocker.

  #### ⭐ Revised 2026-08-09 — an SMR disk carries it, then leaves the building

  ⟨Second revision this session. An intermediate plan had `h-3V35` take the copy
  in-chassis and stay there unplugged; that covered operator error and disk death
  but not chassis-level loss, and it tied up the one CMR 4 TB for the duration.
  Superseded — this is better on both counts.⟩

  **Two copies, and they share no failure mode:**

  | | Disk | Route | Ends up |
  |---|---|---|---|
  | **Primary** | one 4 TB **SMR** (`h-CJE9-smr` or `h-CY72-smr`) | in-chassis over SATA | **removed and relocated to another room** |
  | **Second** | `h-XDAS` (Toshiba 3 TB, on pegasus) | network | stays on pegasus |

  ⚠ **The relocation is a step, not a tidy-up.** The copy runs in-chassis because
  that is convenient; the disk then comes *out* of the case before any destructive
  step and goes to another room. Skipping that leaves a parachute one typo away
  from the shell doing the migration — **the likeliest failure here is wiping the
  wrong device, not a drive dying.**

  1. Copy 2.1 TiB to the SMR disk over SATA
  2. Verify
  3. **Power down, physically remove it, put it in another room**
  4. Proceed

  ⭐ **This is the job SMR is genuinely good at**, and the only role in this design
  where those disks are the *right* tool rather than a tolerated one — see
  `docs/DISK-DRAWER.md`: *"SMR is fine for bulk sequential storage and for staging.
  A migration copy is one long sequential write."* One big sequential write, then
  the disk sits powered off. Nothing about that touches DM-SMR's weaknesses.

  ⚠ **Do not expect the in-chassis copy to be dramatically faster.** DM-SMR
  sustained sequential write runs roughly 100–150 MB/s and 1 GbE is ~110 MB/s
  practical, so both routes land near 5 hours for 2.1 TiB. **The drive is the
  bottleneck, not the interface.** In-chassis is still preferable — no dependency
  on pegasus being up, no saturating the network all evening — just not for speed.

  ⚠ **Why the second copy is not optional here.** `smartctl` raises a
  data-recovery warning on this drive family (`DISK-DRAWER.md`), and a parachute's
  entire job is *being readable once everything else has gone wrong*. That is the
  one role where poor recoverability is least acceptable. `h-XDAS` answers it by
  being **uncorrelated** rather than merely additional:

  | | 4 TB SMR | `h-XDAS` |
  |---|---|---|
  | Vendor | WD | Toshiba |
  | Age | 2023 | ~2012 |
  | Recording | SMR | CMR |

  Different manufacturer, decade and recording technology — close to nothing that
  could fail them together.

  ⚠ **Do not use the two 4 TB SMRs as the pair.** Both are dated `2023-07-03` with
  sequential serials, so they are one batch — `DISK-DRAWER.md` flags the same
  pattern for `h-QUTK`/`h-0X2T`. For correlated-failure purposes two disks from
  one batch are close to one disk.

  ⚠ **LUKS both**, per the warning above.

  ⭐ **`h-3V35` is freed entirely.** It carries no parachute duty and goes straight
  into the bracket for the role below, from day one.

  #### `h-3V35` after the window — qBittorrent's incomplete directory

  **500 GB designated for in-progress torrents**, deliberately *off* the array.
  Sized against an expected working set of ≤300 GB, so roughly 40% headroom —
  which matters more than it sounds, because stalled torrents that never complete
  accumulate here rather than draining.

  **The reason is SnapRAID's model.** Parity assumes mostly-static data. A torrent
  being written is the pathological opposite: every sync sees a changed file, and
  the parity work is spent on data that is about to change again. Keeping
  incomplete downloads off-array means SnapRAID never sees a file until it is
  finished and immutable — which is the state its whole design assumes.

  ⚠ **Move completed files *onto* the pool, not away from it, or hardlinks
  break.** §6.2 step 14 already carries "verify hardlink behaviour inside the *arr
  containers" as an acceptance test, and this is the change most likely to break
  it: hardlinks cannot cross filesystems, so a completed file must land on the
  same filesystem as the library for the *arr apps to link rather than copy. The
  split that works is **incomplete on `h-3V35`, completed onto the mergerfs pool**
  — partial files need no hardlinks, finished ones do.

  **✅ Seeding runs from the pool.** Completed torrents move onto mergerfs and are
  seeded from there, which is not a compromise but the point:

  - **Seeding is read-only**, so a completed torrent is static from that moment —
    exactly the state SnapRAID's model assumes, and it costs parity nothing.
  - **It is what makes the \*arr hardlink free.** The import happens *after*
    qBittorrent's move, so the sequence is `h-3V35` → pool (cross-filesystem copy)
    → pool library (hardlink). That second hop is free only because both ends are
    inside the pool. Seeding from `h-3V35` instead would make the import a real
    copy, store every file twice, and leave the seeding copy outside parity.

  ⚠ **Watch for silent move failures on first setup.** If the destination is
  unavailable or permissions are wrong, qBittorrent can mark a torrent complete
  while leaving the data in the incomplete directory, without complaining. The
  symptom appears months later as an inexplicably full `h-3V35`.

  #### The remaining ~3.5 TB

  ✅ **The sequencing trap that used to live here is gone.** An earlier revision
  had the parachute landing 2.1 TiB on this disk, which meant the partition layout
  had to be settled before the copy or 2.1 TiB would need moving to carve the
  qBittorrent partition out afterwards. **The parachute is no longer on this disk**,
  so it can be partitioned freely, from day one, with nothing to work around.

  ⭐ **Do not wipe the parachute disks when the migration ends** — meaning the
  relocated SMR drive and `h-XDAS`, not this one. Both are otherwise idle, so
  keeping the point-in-time copy through the shakedown period costs nothing and
  buys a fallback for exactly the window where the new layout is least proven.
  Reclaim them once it has earned trust.

  ⟨**A local backup of the Precious tier here was considered and is probably
  redundant.** It would fit easily — 215.6 GiB against 3.5 TB — but the photo tier
  is now ZFS with snapshots, which covers logical loss better than a second copy
  on the same machine, and borg covers the offsite case. A third copy that is
  always mounted in the same chassis protects against little that is not already
  covered. Not ruled out; just not obviously worth a role.⟩

### 6.4 If in-place conversion turns out not to be possible

If the disks fail verification, or you decide you want a clean btrfs layout everywhere, the
copy-based path is: freed 12 TB disk (step 4) + ~20 TB of drawer staging = **~32 TB of
scratch** (updated 2026-08-07 from `docs/DISK-DRAWER.md`; this said 24 TB when the drawer
was believed to hold five disks),
which is enough to evacuate and reformat one 12 TB disk at a time. Three sequential ~19 h
copies plus the sync ≈ **3–4 days elapsed**, mostly unattended, with a longer
no-redundancy window. Workable but strictly worse. **Dropping to single parity first is what
makes even this fallback tractable** — without step 4 you genuinely do not have enough room.

### 6.5 The other moving parts

- **NFS exports** — mount mergerfs at `/mnt/user` and paths are preserved verbatim (§4.6).
  memory-alpha, serenity and `modules/darwin/nfs-mounts.nix` need **zero changes**.
- **`tower.internal` continuity** — the DHCP reservation is MAC-keyed and the bond presents
  its first slave's MAC, so the address should follow. The name is the question: if the
  router derives DNS from the DHCP hostname option, setting
  `networking.hostName = "galactica"` would move the name. **hopper runs AdGuard Home** (`modules/nixos/dns.nix`), so a DNS
  rewrite `tower.internal → <IP>` is a one-line fix and decouples the fleet name from the
  service name permanently. Do that; do not name the host `tower`.
  Also note: the flake used to *assert* `hostName == "liskov"` on the rationale that
  "tower.internal must keep resolving to the Unraid instance". That is obsolete under bare
  metal — the machine now *is* tower.internal — and the assertion has been removed along
  with the rest of the VFIO checks.
- **The bond** — the current PR uses a single NIC on `br0` because the guest needs a bridge.
  Bare metal has no guest, so you can restore the **mode 6 (balance-alb) bond** directly.
  Worth noting balance-alb rewrites per-slave MACs and interacts badly with bridging — so
  this is another thing that gets simpler, not harder, without the VM.
- **LUKS pools** — `/etc/crypttab` entries with keyfiles provisioned by sops-nix
  (`sops.secrets.<name>.path`), ordered before the mergerfs mount. Replaces Unraid's manual
  array-start passphrase. Note the posture change (§3.2).
- **NUT** — becomes trivially simple (§4.7). The VFIO plan's move of NUT server duty to
  memory-alpha is unnecessary here; the host serves the UPS and memory-alpha stays a
  client.
- **The Unraid licence flash** — keep it. It is your rollback for six months, and it costs a
  USB header.
- ⏸ **Container management — deferred, with the criterion recorded.** Step 8 used to bring
  up Dockge. Whether it should is now an open question, and the owner has given the
  deciding criterion: **tailscale proxy configuration, Traefik routing and now backup
  scope should live in the same place as the stack itself.** The name for the alternative
  is *shotgun surgery* — one logical change forcing many small edits scattered across
  unrelated files.

  That criterion points at Nix-owned stacks, and the fleet already demonstrates the shape:
  `traefik.nix`, `arcane.nix` and `beszel.nix` each put the service, its Traefik labels and
  its wiring in one module. Adding a backup tier to that attrset is one more field, not a
  fourth place to remember. The gap is the Dockge-managed stacks under `homelab-stacks/`,
  which are the ones that would have to move.

  **What the decision does *not* have to settle is visibility.** Dockge does management and
  visibility; Nix absorbs the management half, and Beszel covers the rest — so "drop Dockge"
  does not mean "fly blind". `docs/BACKUP.md` §4c has the full argument, including the
  ⚠ `virtualisation.oci-containers.backend` default of **podman** against a Beszel agent
  that watches a *Docker* socket.

  ⟨Decide after the `appdata` pass, which produces the per-container tier map this would
  express.⟩

### 6.6 The pilot — prove backup and migration in miniature, on `partdb`

**Owner's proposal, 2026-08-08, and it is the right shape:** wire a couple of small
services for backup, then test-migrate and restore them onto **memory-alpha** before
galactica exists. A rehearsal at low stakes for two things that are otherwise first
attempted at high stakes.

**`partdb` is the best possible choice, not an arbitrary one.** It is the case that
*generated* the paired-appdata rule (`SHARES.md` §5): attachments live in
`/mnt/user/partdb`, and the database that gives them meaning lives in
`/mnt/user/appdata/partdb`. Restore one without the other and you have a heap of
unlabelled files. So the pilot exercises the exact failure the rule exists to prevent,
at a size where getting it wrong costs nothing.

⚠ **Corrected — that database is SQLite, not MariaDB** as an earlier revision of
this section assumed. Verified against `homelab_stacks`'
`tower/inventory/compose.yaml` (`DATABASE_URL: sqlite:///...`), same correction
as `docs/BACKUP.md` §4d. `hosts/galactica/borgmatic/pilot-partdb.yaml` hooks it
under `sqlite_databases` accordingly.

What it proves, concretely:

| Question | How the pilot answers it |
|---|---|
| Does the borgmatic config shape work? | It either backs up or it does not |
| Does the native database hook produce a *restorable* dump? | Restore it on memory-alpha and open the app |
| Does the paired-appdata rule hold? | Restore data + `appdata` together; then deliberately restore only one and confirm it is useless |
| Does BorgBase append-only actually refuse deletes? | Run `borgmatic prune` from the client key and watch the server refuse (`BACKUP.md` §3) |
| Is the tier → `source_directories` path sound? | It is the same mechanism galactica will use |
| Does a service survive a host move at all? | Container, bind mounts, Traefik routing, DNS |

⚠ **Be clear about what it does not prove.** The pilot says nothing about the array
conversion, SnapRAID, mergerfs, the exposure window, or hardlink behaviour across the
*arr stack — those are galactica-specific and untestable this way. Treating a green pilot
as validation of the migration would be exactly the over-reading this document keeps
warning about elsewhere.

**Second candidate worth adding:** one service with *no* database and a large data
directory, to prove the boring path too. `bambuddy_library` or `webdav` would do.

memory-alpha is the right target: it already runs the container tooling, already mounts
Tower over NFS, and is not the machine being rebuilt.


---
