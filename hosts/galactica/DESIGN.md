# Abandoning Unraid for SnapRAID + mergerfs on bare-metal NixOS

**This is galactica's design of record.** It was commissioned as an *alternative* — a
challenge to the then-in-flight plan of running Unraid as a KVM guest with VFIO
passthrough — and it won the argument. The hypervisor host (`liskov`) has since been
retired and this document became the plan rather than the objection to one. The
adversarial framing is kept as written, because the case against the alternative is the
justification for the choice.

An evaluation for `tower.internal` (Supermicro X9SCM-F, Xeon E3-1230 v2).

> **Reading this cold: `liskov` was the hypervisor host, now deleted.** Where the text
> below argues against "the VFIO plan", "the brief", or PR #37, that is the design this
> one replaced. References to `hosts/liskov/…` files have been retargeted where the
> content survived; where it did not, the citation is marked as retired. Nothing in the
> argument depends on those files still existing — they are cited as evidence of what the
> rejected plan committed to, and git history holds them.

Date of research: 2026-08-07. All version numbers checked against upstream and against the
flake's pinned nixpkgs (`3497aa5c9457a9d88d71fa93a4a8368816fbeeba`, 26.05) on this machine.

**Evidence labels used throughout:** `[upstream-measured]` = a number published by the
project itself; `[community-reported]` = a forum/user report; `[vendor-claimed]` = a
datasheet figure; `[estimate]` = my arithmetic, with the reasoning shown;
`[unverified]` = I could not establish it and you should check.

---

> **Reviewer's verification note (added after the report was written).**
> The load-bearing packaging claims were re-checked by evaluating the repo's *pinned*
> nixpkgs directly, not from recollection:
>
> - **Both `services.snapraid` defects are CONFIRMED from module source.** `ExecStart` is
>   a bare `snapraid sync` with no `diff` or threshold guard, and `snapraid-scrub` carries
>   `unitConfig.After = "snapraid-sync.service"` while both units use independent `startAt`
>   timers — `After=` orders only within a single systemd transaction, so it provides no
>   protection across separate timers. Defaults are sync daily 01:00, scrub `Mon *-*-* 02:00`,
>   one hour apart on an array whose sync is estimated at 12–18 h. These are real and must
>   be fixed before first sync.
> - **`services.mergerfs` does not exist** — confirmed, the option path fails to evaluate.
>   `mergerfs` itself is packaged at **2.41.1**.
> - **One claim was WRONG and has been corrected throughout.** The report originally stated
>   nixpkgs 26.05 ships snapraid **12.4**. It ships **14.4**. The gap to upstream is a point
>   release, not two major versions, so the "significantly behind upstream" stability concern
>   is substantially weaker than the report argued — which makes the recommendation *stronger*,
>   not weaker. The 14.x series itself checks out independently (14.0 released 2026-03,
>   SnapRAID Daemon v1.14 2026-07); the precise upstream point release was not verified.
>
> Everything else below is the research agent's work, unaltered.

---

## 0. Verdict first

**Go bare-metal NixOS with SnapRAID + mergerfs. Abandon the VFIO plan. But not in the shape
the brief assumes, and not in one step.**

The three findings that drive this:

1. **The migration is not a migration.** Unraid's data disks are ordinary, independent
   XFS/btrfs filesystems holding ordinary files. SnapRAID and mergerfs want exactly that.
   You do not need to copy 24 TB through 12 TB of staging — you mount the existing disks
   as-is and repurpose the parity disks. The 12 TB staging constraint that dominates the
   brief is **largely a non-problem**, and this is the single strongest argument for the
   whole plan.

2. **The stated requirement — "double parity for photos" — is solving the wrong problem.**
   SnapRAID parity is up to 24 h stale *and* has a failure mode where churn on *surviving*
   disks can block recovery of the *failed* disk. That is not what you want protecting
   irreplaceable data. Photos want checksummed real-time redundancy (btrfs raid1 on two of
   the spare SSDs) plus an actual offsite backup. Once photos leave the 12 TB array, the
   array-wide-parity structural problem **dissolves entirely** and media can run on single
   parity. That also takes you from 24 TB usable to 36 TB usable.

3. **Bare metal lets you distribute disks across controllers arbitrarily.** VFIO cannot —
   whole controllers go to the guest. Splitting the four 12 TB disks 2-and-2 between the
   onboard C204 SATA3 ports and the ASM1166 removes the Gen2 x2 bottleneck as a
   consideration, and lets you **pull the ASM1064 out of the machine entirely** (you need
   10 ports; onboard 6 + ASM1166 6 = 12). Neither is possible under passthrough.

The costs are real and I do not want to undersell them. The largest are: the nixpkgs
`services.snapraid` module runs `snapraid sync` with **no diff/threshold guard and no
notifications**, which you must build; and mergerfs has a specific, well-known footgun (writing into an
unmounted branch path) that must be configured against deliberately because there is no
NixOS module to do it for you.

Conditions under which each option wins are in §7.

---

## 1. Stability and packaging

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

## 2. Performance on *this* hardware

### 2.1 Establishing the bottleneck: it is the disks, not the 2012 CPU

SnapRAID's per-block work is: hash the data (SpookyHash-128) plus generate parity
(GF arithmetic). The E3-1230 v2 has SSE2/SSSE3/SSE4.2 and AVX, **no AVX2**, so it uses
SnapRAID's `sse2e`/`ssse3e` paths, not `avx2`.

Datapoints, all `[community-reported]` from the
[SnapRAID SourceForge lists](https://sourceforge.net/p/snapraid/discussion/1677233/):

- **Whole-pipeline, measured end to end:** a Xeon **E5540** (Nehalem, 2.53 GHz, 2009 —
  *older and slower per-core than the E3-1230 v2*) sustained **1591 MB/s sync at 98% CPU**,
  breaking down as raid 28% / hash 39% / sched 12%.
- **Component benchmarks (`snapraid -T`):** `gen2 sse2e` at **~10,700 MB/s** on an Intel CPU
  under 11.3; by contrast `gen2 avx2` reaches 25,000–32,000 MB/s. On an Atom, the floor:
  `RAID6 sse2ext` 2481 MB/s, `HASH Spooky2` 3389 MB/s.
- Thread consensus: CPU is the limit only in edge cases; disks and memory bandwidth dominate.

**`[estimate]`** The E3-1230 v2 (Ivy Bridge, 3.3 GHz base / 3.7 turbo) is roughly 1.5–1.8×
the E5540 per core on this kind of workload (IPC + clock). That puts the single-threaded
SnapRAID pipeline ceiling at roughly **2.4–2.9 GB/s**. Note SnapRAID's multithreading is
one I/O thread per disk for read-ahead/write-behind (added in 10.0); the parity computation
itself is one thread, so extra cores do not raise this ceiling.

Now the disk side.

- **HGST HUH721212ALE601:** ~250 MB/s `[vendor-claimed, outer tracks]`. Sequential rate on
  a 3.5" 12 TB helium drive falls to roughly 110–125 MB/s at the inner diameter, so a
  **full-platter average of ~180 MB/s** `[estimate]`.
- Two data disks read in parallel: **~360 MB/s average, ~500 MB/s peak.**
- Three data disks: **~540 MB/s average, ~750 MB/s peak.**

**Verdict: SnapRAID sync on this box has roughly 4–5× CPU headroom. Lack of AVX2 is
irrelevant here.** The disks are the constraint. If you later grew to 8+ data disks the
answer would change; at 3–4 it is not close.

### 2.2 The PCIe link, and why bare metal makes it a non-issue

Budget arithmetic `[estimate, standard PCIe accounting]`:

- **ASM1166 at Gen2 x2:** 5 GT/s × 2 lanes = 10 Gb/s raw; 8b/10b → 8 Gb/s = 1.0 GB/s;
  minus TLP/DLLP overhead → **~850–900 MB/s usable, shared across six ports.**
- **ASM1064 at x1** (Gen2, since the board-wide "PCI Express Port – Gen X = Gen2" setting
  applies): **~425–450 MB/s usable, shared across four ports.**
- **Onboard C204:** 2× SATA3 (6 Gb/s) + 4× SATA2 (3 Gb/s ≈ 270 MB/s usable), behind DMI 2.0
  (~2 GB/s each way). Confirmed board spec
  ([ServeTheHome X9SCM-F review](https://www.servethehome.com/supermicro-x9scmf-sandy-bridge-xeon-lga1155-c204-motherboard-review/)).

Your framing — four 12 TB disks at ~1.0 GB/s aggregate ≈ the entire Gen2 x2 budget — is
correct *if all four sit on the ASM1166*. Under VFIO they must, because controllers pass
through whole. **Under bare metal they need not.**

**Recommended physical layout:**

| Port | Devices | Rationale |
|---|---|---|
| Onboard SATA3 ×2 | 2× 12 TB **data** disks | Full speed, no shared link. These are read on every sync. |
| Onboard SATA2 ×4 | NixOS root SSD, 2× Crucial BX500 480 GB (photo mirror), 1× MX100 512 GB | SATA2 caps these ~270 MB/s. Acceptable; see caveat below. |
| ASM1166 (6) | 1–2× 12 TB (parity + 3rd data), cache SSD, fastservices SSD | Worst case 3 spinners writing/reading ≈ 540 MB/s + SSD traffic, well under ~850 MB/s. |
| **ASM1064** | **remove from the machine** | 10 devices, 12 ports without it. Deletes a card, a slot, an IOMMU group, and a bottleneck. |

Caveat: the BX500s will do ~540 MB/s natively and SATA2 will cap them at ~270. If the photo
mirror's throughput matters, swap them onto the ASM1166 and put two 12 TB disks on SATA2
instead — a 12 TB spinner averaging 180 MB/s is comfortable inside a 270 MB/s port. Decide
by measuring, not by spec sheet.

One correction to the brief's framing: the BIOS Gen2 quirk does **not** stop mattering under
bare metal. The ASM1166 is still invisible at Gen3 and the setting is still required. What
stops mattering is its *criticality* — you are no longer depending on that one link to carry
the whole array's bandwidth, and a dead CMOS battery that resets it (already flagged as a
blocking pre-step in `PLATFORM.md §1` and §5) degrades you instead of destroying you.

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

## 3. Administrative ergonomics

### 3.1 What is genuinely lost

| Unraid provides | Replacement | Honest assessment |
|---|---|---|
| webGUI disk overview, temps, SMART, spin state | `lsblk`, `smartctl`, `snapraid status/smart`, Beszel (already a fleet module) | **Real loss.** Nothing gives you Unraid's one-glance dashboard. Beszel + a small status script recovers most of it. |
| Docker tab, Community Applications templates | **Dockge** — already `modules/nixos/dockge.nix`, already managing `homelab-stacks/` | **Near parity.** Same affordance (browse/edit/restart compose stacks in a browser). You lose CA's one-click templates; you keep 30+ stacks in git, which you already do. |
| VM manager | libvirt, or nothing | Moot — the point is to not have a VM. |
| User shares: split level, allocation method, include/exclude disks | mergerfs create policies + `minfreespace` + branch modes (RW/RO/NC) | **Biggest genuine rebuild.** Unraid's split-level UI is literally the mergerfs policy problem with a GUI on it. Same decisions, no GUI, but now they live in git with a comment explaining why. |
| SMB/NFS share toggles, user management | `services.samba`, `services.nfs.server.exports`, sops-held credentials | Fine, but hand-written. Declarative, which is the point. |
| **Notifications** (disk temp, SMART, array errors, parity results) | ntfy (fleet module) + `OnFailure=` units + a `snapraid status` reporter you write | **The real gap.** nixpkgs' snapraid module emits nothing. Budget a day. SnapRAID Daemon would solve it properly — unpackaged, needs ≥14. |
| Array start/stop, LUKS unlock prompt, parity check scheduling, spin-down | systemd timers, crypttab + sops, `snapraid up/down`, `hdparm`/`hd-idle` | Rebuildable. Spin-down needs care: mergerfs `readdir` touches every branch, so a naive setup keeps disks awake (upstream has a [Limit Drive Spinup](https://github.com/trapexit/mergerfs/wiki/Limit-Drive-Spinup) page). |

### 3.2 What NixOS does better

- **The whole machine becomes reviewable.** `hosts/galactica/configuration.nix` +
  `modules/nixos/{snapraid,mergerfs}.nix`, under the same PR convention, same
  `nix flake check` CI, same `[galactica]`-prefixed titles as the other five hosts. Today,
  `tower` is the one machine in the fleet whose configuration lives in a webGUI and a USB
  stick.
- **Rollback is `nixos-rebuild --rollback`,** not a flash-drive restore. Compare Unraid,
  where the config *is* the flash drive.
- **No licence, no vendor.** No USB GUID to protect, no support ticket to move a licence,
  no "Unraid 7.4 changed the Docker tab".
- **LUKS unlock stops being manual.** Today the Unraid array unlock is a hands-on step
  (a locked constraint of the rejected VFIO plan: *"No auto-unlock for the Unraid
  array"* — it was unlocked inside the guest by Unraid's own machinery, so no host-side
  scheme could remove the manual step, only move it). With sops-nix, keyfiles decrypt at boot under the host SSH key and
  `/etc/crypttab` opens the pools. That is a real ergonomic win — and a deliberate posture
  change: encryption now protects a powered-off stolen chassis, not a running one. Same
  trade the rest of the fleet already made.
- **Everything is one host again.** No hypervisor/guest split, no two places to look.

### 3.3 Day-to-day operations

- **Adding a disk:** format it, mount it at `/mnt/diskN`, add to the mergerfs branch list and
  `services.snapraid.dataDisks`, rebuild, `snapraid sync`. New parity blocks are appended;
  the sync reads only the new disk. Roughly as easy as Unraid, and it is a git commit.
  **Constraint:** each parity disk must be ≥ the largest data disk. With 12 TB parity you can
  add data disks up to 12 TB. A 16 TB disk would force a parity upgrade first.
- **Replacing a failed disk:** see §4.2. Multi-hour to multi-day; comparable to Unraid.
- **Checking health:** `snapraid status` (scrub age graph, bad blocks, parity fragmentation),
  `snapraid smart` (failure probability per disk). Both need wrapping into a scheduled report.
- **Getting alerted:** you must build it. `OnFailure=` → ntfy for the sync/scrub units,
  plus a weekly `snapraid status`/`smart` digest. Non-negotiable — an unwatched SnapRAID
  array is worse than an unwatched Unraid array, because Unraid at least emails you.

---

## 4. Failure modes

This is the section that decides the question.

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

### 4.6 NFS re-export to memory-alpha

Both halves must be right, or memory-alpha gets `ESTALE`/`EIO`:

**mergerfs side:** `never-forget-nodes=true`, `inodecalc=path-hash`,
`lazy-umount-mountpoint=false`.
**Export side:** a distinct `fsid=<uuid>` per export (FUSE filesystems share `st_dev`, so
without this NFS gets confused), and `no_root_squash`.

`hosts/memory-alpha/configuration.nix:257-265` mounts `nfsvers=4 … nconnect=4`. NFSv4 plus
FUSE plus `nconnect` is the least-trodden corner of this whole design — the 2024 EIO bug
lived exactly there. **Test this early and under load, before you depend on it.**

**Path continuity is easy and you should take it:** mount the mergerfs pool at **`/mnt/user`**
and create `jellyfin/` and `arr_managed_data/` inside it. Then
`tower.internal:/mnt/user/jellyfin` and `tower.internal:/mnt/user/arr_managed_data` keep
working verbatim, and **memory-alpha, serenity and the darwin `nfs-mounts` module need zero
changes.**

### 4.7 Unclean shutdown

- **Data disks:** journalled XFS or CoW btrfs. A power cut costs in-flight writes. Same as
  Unraid, same as any Linux box.
- **SnapRAID content files:** fsync'd, with the containing directory also synced (11.3), and
  the module *asserts* ≥ parity+1 copies on different disks. Worst case you lose the last
  sync's bookkeeping and re-run sync.
- **Interrupted `sync`:** resumable — *"You can stop this process at any time by pressing
  Ctrl+C… at the next run it will resume where it was interrupted."* But see §4.2: pre-15.0,
  an interrupted sync leaves a recovery-quality gap. Set `autosave` (e.g. `autosave 500`) so
  progress is checkpointed.
- **Versus Unraid:** an unclean Unraid shutdown triggers an automatic ~20 h parity check.
  SnapRAID's equivalent is "run sync again", which is cheaper. **SnapRAID wins here.**

**The UPS story is where bare metal shines, and the brief undersells it.**
The VFIO plan moved NUT server duty to memory-alpha *specifically because* virtualizing Tower moves the UPS USB to the host, leaving the host — which
physically holds every disk — with no UPS awareness and able to be hard-cut mid-parity-check.
**Bare metal makes that decision unnecessary.** The UPS plugs into the NixOS host,
`modules/nixos/nut.nix` makes it the NUT server, `modules/nixos/nut-client.nix` keeps
memory-alpha as the client, and `ups@tower.internal` keeps resolving. The entanglement
disappears rather than being worked around. That is a genuine architectural simplification
the brief did not list.

### 4.8 Root disk dies vs array disk dies

**Root disk** — the Kingston SH103S3 120 GB when this was written, now slated to be the
1 TB NVMe on a PCIe adapter (§5.5). Recovery: `nixos-install`
from the flake onto a replacement, restore `/etc/ssh/ssh_host_ed25519_key` (or generate a new
one, `ssh-to-age` it, update `.sops.yaml`, `sops updatekeys secrets/galactica.yaml` — a
documented fleet procedure), restore container config/databases from backup, remount the data
disks, remount mergerfs. **The array and parity are untouched.** SnapRAID's content files
already live on the data disks (module assertion), so nothing array-critical is on root.
Realistic: **under an hour of hands-on** plus restore time for container state.

That is dramatically better than Unraid, where the flash drive *is* the configuration and
the licence, and losing it means a support ticket plus reconstructing every share, user and
container definition. **This is the clearest ergonomic win in the whole comparison** and it
is exactly what the rest of the fleet is built to deliver.

Two recommendations regardless:

- **Do not trust a fourteen-year-old 120 GB SSD as the sole root device.** Mirror it (btrfs
  raid1 or mdraid across two of the spare SSDs), or accept the risk explicitly on the
  strength of the 1-hour rebuild. Either is defensible; drifting into it is not.
- **Back up container config/databases off-box** (restic to memory-alpha or hopper). *arr
  databases and Jellyfin metadata are the genuinely irreplaceable non-photo data on this
  machine, and they are small. Requirement #2's honest corollary is *"no parity on media,
  but a real backup of the metadata"* — that backup is what makes re-acquisition tractable,
  because Sonarr/Radarr can only re-fetch what they still know they had.

**Array disk dies:** §4.2. Note the asymmetry — a data disk death is a 1–2 day event with
services degraded; a root disk death is a 1-hour event with services down. The fleet's
declarative model inverts the usual severity ordering, in your favour.

---

## 5. Storage layout: solving the array-wide-parity problem

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

### 5.5 Physical budgets — ports, slots, and the Gen3 question

*Added 2026-08-07 after the report was written, from decisions taken since. This section
supersedes any disk placement implied above.*

**Hardware changes agreed since the report:**

- **BD-ROM → external USB3 enclosure**, off SATA entirely. Note this makes the ASM1042
  load-bearing rather than incidental: the C204 is EHCI only, so that card is the machine's
  *only* USB3. ⚠ **Parked as of 2026-08-08** — the interim LSI cooling arrangement may pull
  the ASM1042 for a slot cooler card, leaving no USB3 host at all. Not a slowdown, a stop.
  See `PLATFORM.md` §7b, which also notes the budget may not force the removal.
- **Kingston 120GB retired → 1TB NVMe on a PCIe adapter.** The Kingston is a 2012 SandForce
  SF-2281 from the era those controllers were notorious for sudden death, and it currently
  holds the root filesystem. 1TB also gives `/nix` real room, which matters with this many
  containers and a large flake closure.
- **No fifth 12TB.** Not affordable at present, so every layout must work with four.
- **Drawer inventory: 3× 4TB, 2× 2TB spinners.** Two of the 4TB become the photo tier —
  4TB of checksummed btrfs raid1 instead of ~450GB on SSDs, which **dissolves the largest
  unverified assumption in this report** (whether photos fit in 450GB). Photos are cold
  data; spinning rust is fine.

  > ⚠ **Corrected 2026-08-07 from photographs of the drives' labels
  > (`docs/DISK-DRAWER.md`).** The drawer holds **twelve** spinners, ~23.5 TB, not five —
  > 3× 4 TB, 4× 2 TB, 3× 1 TB, a 500 GB and a 2.5" oddity. Two consequences for this
  > section, neither of which changes the recommendation:
  >
  > 1. **Only one of the three 4 TB disks is CMR** (`h-3V35`, a Red Plus WD40EFPX). The
  >    other two are WD Red **EFAX**, which are DM-SMR. So the photo tier as written —
  >    two 4 TB in btrfs raid1 — cannot be an all-CMR pair without buying a disk. The
  >    options and their costs are tabulated in `DISK-DRAWER.md`; this is a live decision,
  >    not a settled one. **Whatever else happens, do not put SnapRAID parity on an EFAX**
  >    — scattered parity writes are DM-SMR's worst case.
  > 2. ~~**Staging capacity is ~20 TB, not 12 TB**, counting the 2 TB disks.~~
  >    **Superseded 2026-08-08 — staging capacity is not the constraint and never
  >    was.** Measurement put non-media array data at 2.4 TiB, so the parachute is
  >    **2.1 TiB on one off-box disk**, not a multi-disk staging pool (§6.3,
  >    `DECISIONS.md` §8). **The 2 TB drawer disks stay in the drawer permanently**,
  >    which is what keeps the port budget below closed rather than colliding with
  >    the step-7 ASM1064 removal.
  >
  > Also flagged there: the Samsung 2 TB (`h-8742`) has the 2010-era HD204UI firmware
  > defect where a SMART command during a write can corrupt data. Check its firmware
  > revision before using it for anything — this fleet polls SMART constantly.

**⚠ The NVMe probably will not be bootable.** The X9SCM is a 2011 design and NVMe boot
needs an NVMe DXE driver in firmware, which predates the standard. Linux will see the drive
regardless — the kernel driver is independent of firmware — but the boot menu likely will
not. The workaround is standard and costs no port: **ESP on a SATA device, root and `/nix`
on the NVMe.** systemd-boot only needs firmware to reach the ESP; the initrd loads `nvme`
and pivots. Put the ESP on whichever SSD lands in the scratch role. Test by installing the
adapter and looking for it as a boot option.

**Port budget — this now closes, and only just:**

| Role | Devices | Ports |
|---|---|---|
| Media SnapRAID | 4× 12TB | 4 |
| Photos | 2× 4TB btrfs raid1 | 2 |
| App state | 2× BX500 btrfs raid1 | 2 |
| Scratch / cache (likely consolidates) | WD Blue 500, 223GB SSD, MX100 | 3 |
| Third 4TB | 1 | 1 |
| **Total** | **12** | **12 available** (onboard 6 + ASM1166 6, ASM1064 pulled) |

Root moves to PCIe and the BD-ROM to USB, which is precisely what frees the port that lets
the third 4TB into service. The 2× 2TB stay in the drawer. There is **zero headroom** — any
further disk requires either consolidating the three scratch SSDs (they exist in that shape
because Unraid's cache-and-pools model wanted them to; that reason disappears here) or
keeping the ASM1064.

**PCIe slot budget:** ASM1166 + ASM1042 + NVMe adapter = three of four, with the ASM1064
pulled. Fits. Note §4c's question about relocating the ASM1042 for IOMMU isolation is moot
under bare metal — there are no groups to keep clean.

#### Port speeds are confirmed, and they invert the placement

**Onboard is 2× 6Gb/s + 4× 3Gb/s** — confirmed 2026-08-07, not six alike. The ASM1166 is
SATA3 on all six, but those six share one PCIe link.

Every earlier version of this plan put the array on the ASM1166. That was never a
performance decision — Unraid under VFIO *required* it, because passthrough hands over
whole controllers. Bare metal has no such constraint, and the speeds argue the opposite:

| Ports | Devices | Why |
|---|---|---|
| **Onboard SATA2 ×4** | **4× 12TB array** | 3Gb/s is ~275 MB/s practical, comfortably above the drives' ~250 MB/s — no cap. And it takes the parity check **entirely off the ASM1166's shared link**, onto the PCH, where DMI 2.0's ~2 GB/s is double what four spinners can produce. |
| Onboard SATA3 ×2 | 2× BX500, app-state btrfs raid1 | the two best ports to the most latency-sensitive data |
| ASM1166 ×6 | 3× 4TB (photos raid1 + third) + WD Blue + 223GB SSD + MX100 | photos are cold, the third 4TB idles, scratch SSDs are bursty — none of it contends for sustained bandwidth |

**This dissolves the Gen2 link bottleneck for the array outright**, without depending on the
Gen3 test. §2.2 argued for distributing disks across controllers as a mitigation; the
confirmed port speeds turn that into a straightforward placement rule, and the array simply
stops touching the constrained link at all.

Consequence worth noting: **the Gen3 test no longer gates the array design.** It still
decides the NVMe root's ceiling (~2 vs ~4 GB/s at x4), so it remains worth one reboot, but
the parity check is unaffected either way. One less coupled unknown.

Note this is the exact inverse of the VFIO plan's recabling table, which moved the array
*onto* the ASM1166 — necessarily, since onboard SATA was never passed through and an array
left there would have been invisible to the guest. That table was correct for that plan and
is wrong for this one: a good illustration of how much of the old runbook was load-bearing
only under virtualization. Measured port speeds are in `PLATFORM.md §8`.

#### ⚠ Under SnapRAID the parity disk must be encrypted too — Unraid's property does not carry over

Confirmed 2026-08-07: Tower's data disks and SSD pools are LUKS-encrypted, and
**the two 12TB parity disks are not — because under Unraid they cannot be.** Unraid
parity is raw block-level parity with no filesystem on it. There is nothing to
encrypt.

That is safe today. Unraid computes parity over the *encrypted* blocks, so the
parity disks hold combinations of ciphertext and never see plaintext.

**That property does not survive the migration.** SnapRAID runs in userspace and
computes parity over *files* on *mounted* filesystems — i.e. over plaintext — then
writes it to an ordinary file on the parity disk. If the parity disk is not itself
encrypted, its contents are derived from plaintext and can leak. The parity of
known plaintext is recoverable plaintext.

So: **LUKS the parity disk.** It costs nothing structurally — SnapRAID neither
knows nor cares that its parity file sits on an encrypted filesystem — but it is
silent and easy to miss, because the disk it replaces was legitimately unencrypted
and looked fine that way.

The same reasoning applies to the btrfs raid1 photo tier: it holds plaintext files
and must be encrypted if the current protection level is to be preserved.

#### The Gen3 test is worth more than it was first credited with

`PLATFORM.md §6e` records "set `Gen X` back to Auto and see whether the card still
enumerates" as a *free test* — worth one reboot to find out whether §1's landmine is gone.
With the
NVMe in the picture, the stakes roughly double, because **that BIOS setting almost certainly
governs the slots globally rather than per-port.** One test, three outcomes:

| | Gen2 forced (today) | Gen3 (if the new firmware trains) |
|---|---|---|
| ASM1166 link | ~1.0 GB/s across 6 ports | ~1.97 GB/s |
| Parity check | ≈ the aggregate of 4 spinners — link is a live constraint | comfortable headroom |
| NVMe (x4 adapter) | ~2 GB/s | ~4 GB/s |
| `PLATFORM.md §1` landmine | live; a CMOS clear hides the array controller | **gone permanently** |

The card was flashed 2020-11-05 → 2021-11-08 on 2026-08-07, and improved link training on
older boards is one of the reported reasons for that firmware. **This test should happen
before any disk placement is finalised**, since a Gen3 result removes the link as a design
constraint entirely and makes the "distribute disks across controllers" argument in §2.2 a
nice-to-have rather than a mitigation.

It is still only one reboot, and the failure mode is benign and immediately visible: if the
ASM1166 does not appear at Auto, set it back to Gen2 and nothing is lost.

---

## 6. Migration

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
- **Partition layout.** Unraid partitions array disks itself; check `lsblk`/`parted` and
  confirm the filesystem mounts cleanly read-only from a Linux live environment *before* you
  plan around it.

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
   decision, or on any disk moving. ⟨Confirm the current container image.⟩
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

  ⚠ **It has never been health-tested**, and it is now the single point of failure
  for the whole Protected tier during the window. `smartmontools` is not installed
  on pegasus; `nix shell nixpkgs#smartmontools -c smartctl -a /dev/sdb` costs
  nothing. `DISK-DRAWER.md`'s rule stands: an untested spare is a guess.

  **The copy is network-bound**, not SATA-bound — roughly 5–6 h for 2.1 TiB at
  1 GbE, and it must finish before step 11. A scheduling input, not a blocker.
  ⟨`ethtool enp42s0` for the real figure.⟩

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
`/mnt/user/partdb`, and the MariaDB database that gives them meaning lives in
`/mnt/user/appdata/partdb`. Restore one without the other and you have a heap of
unlabelled files. So the pilot exercises the exact failure the rule exists to prevent,
at a size where getting it wrong costs nothing.

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

### 6.7 Open hardware decisions that gate the layout

Both arrived 2026-08-08 and both are live rather than settled.

**1. CMR disks for the non-SnapRAID tiers.** Only one of the three 4 TB drawer disks is
CMR (`h-3V35`, a Red Plus WD40EFPX); the other two are WD Red EFAX, which are DM-SMR
(`docs/DISK-DRAWER.md`). The owner is pricing one or two CMR replacements. **If they are
cheap, buy them** — it removes the photo tier's blocker outright and is the smallest sum
of money in this plan that unblocks the most.

⚠ Whatever else happens, **no SnapRAID parity on an EFAX.** Scattered parity writes are
DM-SMR's worst case.

**2. ⚠ The LSI 9240-8i — reopened, and it may retire the ASM1166.** An order was placed
and not cancelled, and the owner may prefer it *and return the ASM1166* if it validates.

`DECISIONS.md` carries "no LSI HBA" as a prior ruling — but it records the **conclusion
with no argument**, and it was reached under the VFIO design where whole-controller
passthrough drove the requirements. So there is nothing here to overturn; the question is
simply open, and it should be decided on bare-metal merits.

The case *for* it is stronger than it first looks:

- **It deletes `PLATFORM.md` §1's landmine permanently.** The ASM1166 is invisible unless
  the BIOS carries `PCI Express Port - Gen X = Gen2` *and* `Detect Non-Compliance Device =
  Enabled`. **A CMOS clear or a dead battery makes the array controller vanish and look
  like hardware failure.** That trap does not exist with an LSI card, and §5 of PLATFORM
  already flags the CMOS battery as aging.
- **Bandwidth stops being a design constraint.** The 9240-8i is PCIe **2.0 x8** —
  roughly 4 GB/s, against the ASM1166's shared ~1.0 GB/s at Gen2. Four spinners at
  ~250 MB/s is 1.0 GB/s, i.e. *the entire* ASM1166 Gen2 budget and a quarter of the LSI's.
  It also makes the §6e Gen3 retest irrelevant to the array.
- **Eight ports instead of six**, which restores the headroom §5.5 currently does not have.
- **SAS2008 is a genuinely well-supported HBA** — `mpt3sas` is in-tree and maintained,
  SMART passes through cleanly, and it is the standard recommendation for exactly this job.

⚠ The costs are real and should not be discovered mid-migration:

- **It must be crossflashed to IT mode.** Stock 9240-8i firmware is IR/MegaRAID and does
  not present raw disks properly. This is well-trodden but is a flashing procedure on a
  card that boots its own option ROM — and `PLATFORM.md` §6 is a standing reminder of how
  a "routine" controller flash on this machine actually goes. ⟨Budget a day, not an hour.⟩

  ⚠ **The vendor states it is already flashed. Verify rather than accept** —
  `PLATFORM.md` §7b is the procedure. One command settles whether the flash happened at
  all (the firmware personality changes the PCI device ID: `1000:0073` is stock MegaRAID,
  `1000:0072` is MPT), and the section separates that from the *authenticity* question,
  which is a different check with a different answer. Note that `sas2flash` is not
  packaged in nixpkgs, so plan for it.
- **Cables.** It needs 2× SFF-8087 → 4× SATA *forward breakout*, usually not included.
  Buying the wrong direction (reverse breakout) is a common and annoying mistake.
- **Heat.** SAS2008 expects server airflow and runs hot passively. Check it under a
  sustained sync, not at idle.
- **Validate before returning anything.** The ASM1166 was flashed on 2026-08-07 at some
  cost in effort; that is sunk and should not influence the decision — but the return
  window is a *deadline*, and the validation is a full parity-check-equivalent load test,
  not a boot-and-see. Sequence it accordingly.

**If the LSI wins, §5.5's port budget and placement table are rewritten**, and the
"distribute disks across controllers" reasoning in §2.2 becomes moot. Do not finalise disk
placement until this is decided.

---

## 7. Recommendation

### The verdict

**Adopt bare-metal NixOS with SnapRAID + mergerfs. Abandon the VFIO plan.**

*Outcome, 2026-08-07: accepted. The `liskov` hypervisor host was deleted and this branch
continues as galactica's; PR #37 was retitled rather than closed, so this document and the
hardware notes it depends on stay in one reviewable history.*

The VFIO plan is well-engineered — its IOMMU group analysis is correct, the ACS-override
refusal is right, and passthrough was validated on real hardware (ASM1166 bound to
`vfio-pci` on pegasus, 2026-08-07, with `ahci` present and losing the race). None of that
is the problem. The problem is that it spends real complexity to
*preserve* Unraid, and the things it must work around are all consequences of that choice:

- an indivisible IOMMU group forcing an unwanted USB3 controller into the guest;
- the licence flash as a passed-through physical device;
- the Gen2 BIOS setting becoming load-bearing, on a 2011 board with a suspect CMOS battery;
- **the whole four-disk array pinned to one Gen2 x2 link**, because controllers pass through
  whole and you cannot split them;
- NUT server duty displaced to memory-alpha to work around the host having no UPS awareness
  (decision 9);
- a bridge instead of the existing bond, to make the guest's identity match bare metal;
- and hand-maintained libvirt XML that is explicitly *not* declarative (decision 6) — sitting
  inside a fleet whose entire premise is declarative reproducibility.

Bare metal deletes every one of those. It also lets you distribute disks across controllers,
remove the ASM1064, restore the bond, keep the UPS local, and bring the last non-declarative
host into the fleet's model. And the migration is far cheaper than anyone expected, because
Unraid's per-disk independent filesystems are exactly what the target wants.

### Conditions under which each option wins

**Keep Unraid on bare metal (do nothing) wins if:**
- You will not build the missing pieces — the `snapraid diff` threshold guard, the ntfy
  alerting, the mergerfs safety options. **An unmonitored SnapRAID array with an unguarded
  nightly sync is materially more dangerous than Unraid**, because the sync can destroy
  recoverability in a way Unraid's always-current parity never can. If you are not going to
  build the guard rails, do not take the guard rails away.
- You value real-time parity and the emulated-disk-stays-online behaviour more than
  declarative config. That is a legitimate preference for a 24/7 media server.
- **Note: you can take the entire capacity and photo-protection win (§5.4) without leaving
  Unraid.** Drop to single parity, put photos on a btrfs raid1 pool, back them up offsite.
  24 TB → 36 TB, better photo protection, one afternoon, near-zero risk. **If you only do
  one thing from this report, do that one.**

**The virtualization plan wins if:**
- You want the whole fleet declarative *and* you are unwilling to accept stale parity.
  It is the only option that gives you both.
- You want a staged path with an instant rollback (shut down the guest, boot the flash).
  Bare metal's rollback is also "boot the flash", but degrades once you write to the disks
  from NixOS.
- You want to keep the option of running other VMs. Bare metal can still run libvirt without
  VFIO, so this is weak.

**Bare-metal NixOS + SnapRAID + mergerfs wins if** — and I believe this describes you:
- Declarative reproducibility across the whole fleet is the actual goal, and the one machine
  that opts out is the one that annoys you.
- 24 h stale parity is acceptable — you said it is, and you can make it **≤6 h** for free by
  syncing four times a day.
- Media parity can drop to one disk (it can) and photos can move off the array (they should).
- You will build the four missing pieces. They are a weekend, not a project:
  1. a `snapraid diff` threshold wrapper in front of `sync` — **do this first, before the
     first sync ever runs**;
  2. `OnFailure=` → ntfy on both units, plus a weekly `snapraid status`/`smart` digest;
  3. `modules/nixos/mergerfs.nix` with structured options and assertions on the
     mount-safety settings;
  4. restic backups of container config/*arr databases to another fleet host.

### Sequencing I would actually follow

1. **Now, under Unraid:** photos → btrfs raid1 SSD pool + offsite backup. Drop to single
   parity. Verify disk health. (Reversible, big win, zero platform risk.)
2. **Then decide.** Steps 1's benefits are independent of the platform question, and having
   done them you can evaluate the platform question calmly rather than as part of a
   photo-protection emergency.
3. **If proceeding:** build the four missing modules against a scratch setup (three loopback
   files will do) and prove the `diff` guard fails closed — the same discipline the VFIO
   plan's eval-time invariants applied, where both guards were confirmed to fail closed
   rather than merely to pass.
4. **Then** the Phase 2–3 conversion, keeping the Unraid flash and the 12 TB staging
   parachute until the first `snapraid sync` completes clean.

### Things I could not establish

- ~~**Total photo size**, and therefore whether ~450 GB of mirrored SSD is sufficient.~~
  **Largely dissolved 2026-08-07** — see §5.5. Photos move to 2× 4TB drawer disks in btrfs
  raid1, giving 4TB rather than ~450GB, so the layout no longer hinges on the answer. Still
  worth measuring, but it is no longer load-bearing.
- **Whether the ASM1166 trains at Gen3 on the new firmware** (§5.5). One reboot. Now
  narrower than it was: it caps the NVMe root (~2 vs ~4 GB/s at x4) but **no longer gates
  the array design**, since the confirmed port speeds put the array on onboard SATA2 and
  off the constrained link entirely.
- ~~**Onboard SATA port speeds.**~~ **Confirmed 2026-08-07: 2× 6Gb/s + 4× 3Gb/s.** See §5.5
  — this is what inverts the placement relative to the VFIO plan.
- **Whether the X9SCM firmware can boot from an NVMe on a PCIe adapter.** Almost certainly
  not, given a 2011 board and a standard that postdates it. The ESP-on-SATA workaround in
  §5.5 is standard and costs no port, but confirm before relying on either answer.
- ~~**Whether the four 12 TB array disks are LUKS-encrypted** under Unraid.~~
  **Answered 2026-08-07** — data disks yes, parity disks no *and cannot be*, since
  Unraid parity carries no filesystem. Safe there because parity is computed over
  ciphertext; **not** safe under SnapRAID, which parities plaintext files. See
  §5.5. ~~Inferred from `lsblk`; confirm against Unraid's own view.~~ **Confirmed
  2026-08-07 from Unraid's Main tab: both data disks and all three pools are
  encrypted, both parity disks carry no filesystem.** `s-3100` (MX100) is
  unassigned and NTFS, and the `/mnt/services` btrfs removal completed.
- ~~**Actual used bytes per data disk.**~~ **Closed 2026-08-07, and the news is
  good.** The brief's "24 TB of data" was capacity, not occupancy. Actual: **Disk 1
  9.05 TB used / 2.95 TB free, Disk 2 8.06 TB / 3.94 TB — 17.1 TB used of 24 TB,
  6.88 TB free**, plus 240 GB on Services, 38.5 GB on Fastservices and 9.31 GB on
  Cache. So roughly **17.4 TB total, not 24 TB**, and the disks are ~71% full
  rather than essentially full.

  Two consequences. The in-place path has real slack rather than none. And 17.1 TB
  fits inside the drawer's ~20 TB of staging (`docs/DISK-DRAWER.md`), so **the
  copy-based fallback is viable end-to-end without winnowing first** — it stops
  being a precondition and becomes an optimisation.
- **Unraid's on-disk partition offset** on these specific disks — verify it mounts cleanly
  from a Linux live environment before planning around in-place conversion.
- **Whether `nconnect=4` NFSv4 over mergerfs is trouble-free.** This is the least-trodden
  path in the design and the historical source of the worst mergerfs bug. Test under load.
- **The quality of `btrfssnapraid`** (or any third-party snapshot-before-sync wrapper). I
  found it; I did not evaluate it.
- **Real `snapraid -T` numbers on an E3-1230 v2.** My CPU-headroom conclusion rests on
  extrapolation from a Nehalem E5540 measurement. The conclusion is robust — the margin is
  4–5× — but the specific number is an estimate. `snapraid -T` takes ten seconds; run it.

---

## Sources

SnapRAID: [HISTORY](https://github.com/amadvance/snapraid/blob/master/HISTORY) ·
[manual](https://github.com/amadvance/snapraid/blob/master/doc/snapraid.txt) ·
[releases](https://github.com/amadvance/snapraid/releases) ·
[snapraid-daemon](https://github.com/amadvance/snapraid-daemon/) ·
[SourceForge discussion archive](https://sourceforge.net/p/snapraid/discussion/1677233/)

mergerfs: [repo](https://github.com/trapexit/mergerfs) ·
[releases](https://github.com/trapexit/mergerfs/releases) ·
[passthrough.io](https://github.com/trapexit/mergerfs/blob/master/mkdocs/docs/config/passthrough.md) ·
[rename and link](https://github.com/trapexit/mergerfs/blob/master/mkdocs/docs/config/rename_and_link.md) ·
[moveonenospc](https://github.com/trapexit/mergerfs/blob/master/mkdocs/docs/config/moveonenospc.md) ·
[branches / branches-mount-timeout](https://github.com/trapexit/mergerfs/blob/master/mkdocs/docs/config/branches-mount-timeout.md) ·
[known issues and bugs](https://github.com/trapexit/mergerfs/blob/master/mkdocs/docs/known_issues_bugs.md) ·
[technical behavior and limitations](https://github.com/trapexit/mergerfs/blob/master/mkdocs/docs/faq/technical_behavior_and_limitations.md) ·
[remote filesystems / NFS](https://github.com/trapexit/mergerfs/blob/master/mkdocs/docs/remote_filesystems.md) ·
[quickstart](https://github.com/trapexit/mergerfs/blob/master/mkdocs/docs/quickstart.md) ·
[Linux 6.9 FUSE passthrough](https://www.phoronix.com/news/Linux-6.9-FUSE-Passthrough)

NixOS: `nixos/modules/services/backup/snapraid.nix`, `pkgs/by-name/sn/snapraid/package.nix`,
`pkgs/tools/filesystems/mergerfs/{default,tools}.nix` — read from the flake's pinned nixpkgs
`3497aa5c` and from the 26.11 tree, both present in this machine's store ·
[services.snapraid options](https://mynixos.com/nixpkgs/options/services.snapraid) ·
[NixOS Discourse: mergerfs + snapraid](https://discourse.nixos.org/t/feedback-and-advice-on-setting-up-mergerfs-snapraid-in-nixos/58290) ·
[josecriane/nixos-nas](https://github.com/josecriane/nixos-nas) ·
[snapraid-aio.nix](https://github.com/TophC7/snapraid-aio.nix)

Hardware / Unraid: [ServeTheHome X9SCM-F review](https://www.servethehome.com/supermicro-x9scmf-sandy-bridge-xeon-lga1155-c204-motherboard-review/) ·
[Unraid data recovery docs](https://docs.unraid.net/unraid-os/troubleshooting/common-issues/data-recovery/) ·
[Unraid forums: dual→single parity](https://forums.unraid.net/topic/98267-downgrading-from-dual-to-single-parity/) ·
[Unraid forums: array write performance](https://forums.unraid.net/topic/196614-slow-write-performance-to-array-is-this-typical-or-is-there-a-problem)

Repo context (read, not modified): `CLAUDE.md`, `flake.nix`, `flake.lock`,
`hosts/liskov/{configuration.nix,DECISIONS.md,BACKGROUND.md}` (since retired — see git
history),
`hosts/memory-alpha/configuration.nix`, `modules/nixos/{dns,dockge,ntfy,nut-client}.nix`,
`modules/darwin/nfs-mounts.nix`.
