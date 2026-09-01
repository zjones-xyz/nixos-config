# Tower — hardware map

Disks installed in this machine, its controllers, bays and cabling.

Naming and labelling rules are fleet-wide and live in `docs/DISK-LABELLING.md`.
Unassigned spare disks live in `docs/DISK-DRAWER.md`.

**Scope: platform-independent.** This describes hardware, not configuration, and
holds whether the box stays on Unraid or becomes bare-metal NixOS per
`DESIGN.md`. It is filed under `hosts/galactica/` because that is the fleet
identity Tower's NixOS host will carry; the disks and cages do not care.

BIOS quirks, BMC access, controller firmware and bus speeds are in
`PLATFORM.md` — this file says *what is plugged into what*, that one says *what
the machine does with it*.

Dates are UTC.

---

## 1. Installed disks

**Read from Unraid's Main tab, 2026-08-07** — roles, filesystems, encryption and
usage are all as that page reported them, not inferred. All error counts zero;
temperatures 30–39 °C.

| ID | Device | Size | Full serial | Role | `sdX` | FS | Used / free | Enc. |
|---|---|---|---|---|---|---|---|---|
| `h-X4WE` | HGST HUH721212ALE601 | 12 TB | `8CJZX4WE` | **Parity** | `sde` | — | — | n/a |
| `h-HJDH` | HGST HUH721212ALE601 | 12 TB | `8DKUHJDH` | **Parity 2** | `sdd` | — | — | n/a |
| `h-T97E` | HGST HUH721212ALE601 | 12 TB | `8CG7T97E` | **Disk 1** (data) | `sdf` | btrfs | 9.05 TB / 2.95 TB | **yes** |
| `h-NS3Y` | HGST HUH721212ALE601 | 12 TB | `8DJPNS3Y` | **Disk 2** (data) | `sdg` | btrfs | 8.06 TB / 3.94 TB | **yes** |
| `s-3255` | WD Blue SA510 | 500 GB | `244964803255` | **Cache** pool | `sdb` | btrfs | 9.31 GB / 487 GB | **yes** |
| `s-9545` | SATA SSD (generic) | 240 GB | `19013024009545` | **Fastservices** pool | `sdc` | btrfs | 38.5 GB / 199 GB | **yes** |
| `s-768C` | Crucial BX500 | 480 GB | `2422E8B6768C` | **Services** pool, dev 1 | `sdh` | btrfs | 240 GB / 239 GB | **yes** |
| `s-8162` | Crucial BX500 | 480 GB | `2506E9A58162` | **Services** pool, dev 2 | `sdi` | *(same pool)* | *(same pool)* | **yes** |
| `s-3100` | Crucial MX100 | 512 GB | `15090EE23100` | ⚠ **unassigned** | `sdj` | **ntfs** | not mounted | **no** |
| `s-5509` | Kingston SH103S3120G | 120 GB | `50026B7239015509` | ⚠ **Boot pool slot** — see below | `sdk` | unmountable | — | **no** |

**Array total: 24 TB, 17.1 TB used, 6.88 TB free.** That is the number the
migration plan turns on — see `DESIGN.md` §6, where it closes an assumption.

### 2026-09-01 — current physical/logical state, read live under NixOS

Read directly on the booted NixOS system (`lsblk`, `/dev/disk/by-id`) after the
SATA/SAS cables were reconnected for the array build. **This is the source of
truth for the ZFS pool config**, superseding the Unraid-era roles above (kept
for provenance). `sidepool` is deliberately **disconnected** for this phase —
its disks are the only staging copy, so keeping them physically out during
destructive pool creation removes any chance of targeting them by mistake (see
the `project-galactica-zfs-pivot` reasoning) — and so does not appear below.
The Kingston `s-5509` boot-pool disk is also absent, not reconnected.

`sdX` names are noted only as they enumerated **this boot**; they are *not*
stable across reboots. Build the pool against the `by-id` paths, which are
serial-derived and stable.

| ID | Model | Serial | `by-id` (stable) | This-boot `sdX` | Intended role |
|---|---|---|---|---|---|
| `h-HJDH` | HGST HUH721212ALE601 12 TB | `8DKUHJDH` | `ata-HUH721212ALE601_8DKUHJDH` | `sdc` | RAIDZ1 member |
| `h-NS3Y` | HGST HUH721212ALE601 12 TB | `8DJPNS3Y` | `ata-HUH721212ALE601_8DJPNS3Y` | `sde` | RAIDZ1 member |
| `h-X4WE` | HGST HUH721212ALE601 12 TB | `8CJZX4WE` | `ata-HUH721212ALE601_8CJZX4WE` | `sdg` | RAIDZ1 member |
| `h-T97E` | HGST HUH721212ALE601 12 TB | `8CG7T97E` | `ata-HUH721212ALE601_8CG7T97E` | `sdi` | RAIDZ1 member |
| `s-768C` | Crucial BX500 480 GB | `2422E8B6768C` | `ata-CT480BX500SSD1_2422E8B6768C` | `sdb` | special vdev |
| `s-8162` | Crucial BX500 480 GB | `2506E9A58162` | `ata-CT480BX500SSD1_2506E9A58162` | `sdf` | special vdev |
| `s-3255` | WD Blue SA510 500 GB | `244964803255` | `ata-WD_Blue_SA510_2.5_500GB_244964803255` | `sda` | special vdev |
| `s-3100` | Crucial MX100 512 GB | `15090EE23100` | `ata-Crucial_CT512MX100SSD1_15090EE23100` | `sdd` | special vdev **+ future ESP host** |
| `s-9545` | SATA SSD (generic) 224 GB | `19013024009545` | `ata-SATA_SSD_19013024009545` | `sdh` | **midden** — `/boot`, `/var/log/journal`, nix build scratch |
| — | SPCC M.2 PCIe SSD 932 GB | `AA2300905N401KG00206` | `nvme-SPCC_M.2_PCIe_SSD_AA2300905N401KG00206` | `nvme0n1` | LUKS root (`cryptroot`) + swap + vestigial ESP |

Notes for the pool build:
- The two BX500s carry **distinct** serials, so the correlated-failure split
  (one BX500 per special-vdev mirror, each paired with a non-BX500) is cleanly
  expressible by `by-id`.
- `s-3100` (MX100) still carries **two leftover partitions** from its Unraid
  life (a ~476 GB data partition + a ~468 MB stale ESP). It is earmarked to
  host `/boot` *and* a special-vdev partition, so partition **around** the
  planned allocation — do not blind-wipe the whole disk.
- `sdc1/sde1/sdg1/sdi1` (the four 12 TB) almost certainly still hold the
  **original array data** — the very data copied to `sidepool`. Wiping them for
  RAIDZ1 is the destructive step; its safety net is `sidepool`'s verified copy
  being present but disconnected.

### `sidepool` — a fifth pool, missing from the 2026-08-07 Main-tab reading above

**Not read from Unraid's Main tab like the rest of §1** — discovered
2026-08-31 from a live NixOS boot (`hosts/galactica/live-iso.nix`), by
`lsblk`-ing the whole machine and finding four `crypto_LUKS` disks that
matched none of the serials above. Called `sidepool` by the owner; functions
as Unraid's staging area for the migration.

| Serial | Size | Model | LUKS |
|---|---|---|---|
| `76HE4XDAS` | 2.7 TB | TOSHIBA DT01ACA300 | yes |
| `WD-WXD2D534CY72` | 3.6 TB | WDC WD40EFAX-68JH4N1 | yes |
| `WD-WXM2D72D3V35` | 3.6 TB | WDC WD40EFPX-68C6CN0 | yes |
| `WD-WXD2D534CJE9` | 3.6 TB | WDC WD40EFAX-68JH4N1 | yes |

**One btrfs filesystem spanning all four** (`blkid` shows a shared `UUID` plus
a per-device `UUID_SUB` — btrfs's own multi-device signature), ~13.5 TB raw,
10.56 TiB used. Confirmed 2026-08-31: opens with the same passphrase as the
main array, and mounts **read-only** cleanly and completely — `btrfs
filesystem show` lists all four devices present, none missing.

Two top-level directories once mounted:

- **`pools/`** — `cache`, `fastservices`, `services` (names matching the three
  real pools above), plus `unraid_config` (root-only) and
  `unraid_flash.img` — **30,752,636,928 bytes, exactly the documented size of
  the Unraid boot flash** (§1 above — the SanDisk Ultra, 28.6 GB), with an
  mtime from the day it was checked. A current, full image backup of the boot
  media.
- **`move_aside/`** — directories matching real share names from `SHARES.md`
  (`arr_media`, `documents`, `immich_photos`, `jellyfin`, `music`, `books`,
  `ha_backup`, etc.), plus dated `ab_2026MMDD_*` folders — almost certainly
  weekly appdata-backup snapshots.

⚠ **Relevant to `DESIGN.md`'s Phase 0 backup concern about the Unraid flash
and config being unrecoverable** (§6.2 step 1) — at least that half of the
insurance already exists here and looked current as of this reading. Worth
confirming it's still being refreshed before leaning on it, but this changes
"we need to back this up" to "confirm this backup stays good."

The WD40EFAX model matches `PLATFORM.md` §7b's drawer-spare disks exactly,
consistent with `sidepool` being built from drawer disks as its name implies.

⚠ **`sdX` letters are not stable** across reboots or recabling. They are recorded
because they were captured in the same reading as everything else and make the
sysfs port lookup in §3 cheaper; **map by serial, never by `sdX`.**

**The Services pool is a two-device btrfs mirror.** 479 GB usable from two 480 GB
devices is raid1 by arithmetic — a stripe would show ~960 GB. So the pair is
redundant, not aggregated, and losing one BX500 costs no data.

⚠ **`s-3100` (MX100) is out of the array entirely** and now carries an **NTFS**
filesystem, unmounted, listed under Unassigned Devices. This retires the open
question about `btrfs device remove missing /mnt/services`: the Services pool
shows both BX500s online and healthy, so **that operation completed** and the
MX100 was reformatted afterwards. It also explains the earlier `lsblk` reading of
"two partitions, 476 G + 468 M" with no `crypt` layer — that is an ordinary NTFS
layout with a Microsoft reserved partition, not a damaged pool member.

⚠ **`s-5509` (Kingston) is assigned to Unraid's `Boot` pool slot**, reporting
*"Unmountable: unsupported or no file system"*, while the page also says *"Internal
Boot: No internal boot setup detected."* So Unraid 7's internal-boot feature was
started and never completed, and the disk still carries the previous Linux install:
1 M BIOS boot, 510 M vfat ESP, **111.3 G `zfs_member`**, 1.4 M remainder. The root
was **ZFS**, not ext4 or btrfs — worth knowing before assuming a stray `mount` will
read it, and worth a `zpool import -N` look if anything on it is wanted before the
disk is wiped.

**This matters for retirement.** The Kingston is not merely unused — it is
*assigned in Unraid's configuration*. Unassign it there before repurposing the
disk, so a fallback boot into Unraid does not come up referencing a device that
has been wiped and handed to NixOS.

### Not yet installed

| ID | Device | Size | Full serial | Notes |
|---|---|---|---|---|
| `m2-140B` | **Silicon Power UD90**, M.2 **2230**, NVMe PCIe Gen 4 ×4, on a PCIe adapter | 1 TB | `23049339-090140B` | Intended root, replacing `s-5509`. **No physical label** — no cable to trace, unambiguous by location, and no room on the card. Identifier is for inventory only. |

Read off the drive's own label 2026-08-07 and confirmed by the owner. **2230, not
2242** as an earlier revision recorded.

Two characteristics worth having on record:

- **Controller is a Silicon Motion SM2269XT** (PCB silkscreen
  `SM2269XT_M2-30_W067A_V0C_1130Y22`, one BGA272 NAND package). It is
  **DRAM-less**, using host memory buffer — unremarkable with 32 GB of RAM, but a
  property of the root device worth knowing rather than discovering.
- **PCIe Gen 4 ×4.** On this board's forced Gen2 (§0) that is roughly 2 GB/s
  assuming the adapter and slot both give ×4; about 3.9 GB/s if the Gen3 test in
  `PLATFORM.md` §6e succeeds. Either is several times the Kingston it replaces.
  **The Gen 4 is dormant** — this platform has no Gen4 anywhere, the CPU tops out
  at Gen3 and the C204 at Gen2. Not a bad buy (Gen4 is the current market and is
  backwards compatible), just not a property this machine can use.
- ⚠ **A PCH slot would cost more than the halved link suggests**, because that
  traffic then crosses **DMI 2.0** — also ~2 GB/s, and shared with the onboard SATA
  carrying the array. Prefer a CPU-attached slot; `PLATFORM.md` §7b has the
  topology test that distinguishes them.

### Not a disk, but on the bus

The Unraid licence flash is a SanDisk Ultra, 28.6 GB, `0781:5581`, on the
**internal USB header** (moved there from a rear port on 2026-08-07). USB, not
SATA, so it takes no port from the budget. Relevant only while Unraid is in play.

---

## 2. Encryption

Everything is LUKS **except where the platform prohibits it**, and there are two
such cases.

**Confirmed against Unraid's Main tab, 2026-08-07.** This section was previously
inferred from `lsblk` device-mapper layers; the Main tab shows a padlock on both
data disks and on all three pools, and no filesystem at all on either parity disk.
**The inference was right in every particular** — recorded because a confirmed
reading and a lucky guess are worth distinguishing.

**The two 12TB data disks are encrypted**, as are **all three pools** — Cache,
Fastservices and Services. Under `lsblk` the data disks surface as `md1p1` and
`md2p1` with `crypt` layers, Unraid's md devices sitting over the raw members.

**The two 12TB parity disks are not, and cannot be.** Unraid parity is raw
block-level parity with no filesystem on it — there is nothing to encrypt. This
is the "Unraid prohibited it" case.

> This does **not** leak anything today. Unraid computes parity over the
> *encrypted* blocks, so the parity disks hold combinations of ciphertext, never
> plaintext.
>
> ⚠ **That property does not survive a move to SnapRAID.** SnapRAID runs in
> userspace and computes parity over *files* on *mounted* filesystems — i.e. over
> plaintext — then writes it to a file on the parity disk. If that parity disk is
> not itself encrypted, the parity content is derived from plaintext and can leak.
> **Under SnapRAID the parity disk must be LUKS-encrypted too.** Recorded in
> `DESIGN.md` §5.5.

**The flash drive is not encryptable.** Unraid's boot device holds the licence and
config and must be readable by the bootloader. The second prohibited case.

**`s-3100` (MX100) is unencrypted, and no longer part of anything** — unassigned,
NTFS, unmounted (§1). The `btrfs device remove missing /mnt/services` question it
was entangled with is closed: the Services pool is a healthy two-device mirror
and this disk is out of it.

**`s-5509` (Kingston) is not encrypted** and carries a previous Linux install — a
1 M BIOS boot partition, a 510 M vfat ESP, a 111.3 G **`zfs_member`** partition and
a 1.4 M remainder. Still occupying Unraid's `Boot` pool slot (§1); being retired
regardless.

---

## 3. Cages

### System identity — read 2026-08-09, `dmidecode`

**This is an integrator build, not a Supermicro barebones and not a whitebox.**
Worth stating because it decides where documentation comes from.

| Field | Value |
|---|---|
| System manufacturer | **Seneca** (Seneca Data, a US integrator) |
| System product | **`pro499926`** |
| System serial | `1212363` |
| Baseboard | Supermicro **X9SCL/X9SCM**, version `1.11A`, serial `ZM148S009088` |
| Chassis, **actual** | **Chenbro `SR20969`** — SR209-series ATX tower. Suffix read as `-01`, ⚠ last character uncertain |
| Originally sold as | A **Windows Storage Server 2012 Workgroup** appliance |

⚠ **SMBIOS reports the chassis as `Supermicro / Type: Desktop`, and that is
wrong.** It is board-supplied default data — the same defaulting that leaves the
chassis *Version* and *Serial* fields reading `0123456789`. **The case is a
Chenbro.** That mistake cost a search for a `CSE-` sticker which does not exist;
**trust the printed part number over SMBIOS.**

⟨A Supermicro logo on the front panel was reported and then doubted by the same
observer within the hour, so it is recorded as *not evidence* in either direction
rather than quietly dropped. It has no bearing on the identification, which rests
on the part number and the bay count below.⟩

**Corroborated physically, which is what settles it.** The SR209 specification
lists **three external 5.25" bays**, and this chassis has three. Combined with the
four hot-swap 3.5" bays, that is two independent structural matches against the
part number — evidence that does not depend on anyone's recollection of a badge.

⚠ **The Seneca product number is a dead end.** Seneca Data was acquired by Arrow
Electronics in 2014 and has since exited that line; `pro499926` returns nothing.
It is an integrator SKU, not a chassis model.

**`SR20969` is the useful identifier**, and it is the confident part — it matched
a real Chenbro family on the first search, which a misread would not have.

**Chenbro is still trading and hosts its own archive**, which beats the manual
scraper sites:

| | |
|---|---|
| SR209 user manual | `chenbro.com/en-US/DownloadFile/download/987` |
| SR209 **Plus** manual | `chenbro.com/en-US/DownloadFile/download/1645` |
| Download centre | `chenbro.com/en-US/Support/download_center/Page/1?p_cat_sn=234&p_sn=271&cat_sn=1126` |

⟨**Links unverified.** The session that found them could not open `chenbro.com`
— egress-blocked — so these come from search results rather than from reading the
documents. Confirm the bay counts on the first page before trusting anything
inside.⟩

⚠ **SR209 and SR209 *Plus* are separate products.** This chassis is `SR20969`
with no `+`, and listings pair `SR20969-C0` with the base SR209 series while
`SR20969+` is the Plus — so the base manual is the likely match.

⚠ **The suffix is the uncertain part** — read as `-01`, last character not
confidently. It denotes the drive configuration, and the family ships several
(`-C0`, `-C4+`, Plus). **Do not resolve this from a listing for a sibling SKU.**

**And it barely matters**, because the layout has already been observed directly:
four hot-swap 3.5" bays (cage A) plus five 2.5" positions in the floor. Counting
what is physically bolted in beats a SKU lookup, and the manual is wanted for
*how the mounts work*, not for how many there are.

**Original licence ceiling explains the build.** WSS 2012 Workgroup permits one
socket, 32 GB RAM and six disks — and this machine reports exactly one physical
CPU and exactly 32768 MB. It was specced to the licence, not generously.
⚠ It now carries **eleven** SATA disks, so most of what is installed today sits
outside anything the original configuration accounted for. That is the likely
reason §3's cages resisted enumeration: past the stock bays, placement was
improvised.

### 2.5" mounting

**The chassis floor carries five 2.5" mounting positions** — owner-observed
2026-08-09, tabs positioned for 2.5" drives.

⚠ **They are not currently in use.** The SSDs sit in an **owner-printed cage**,
not stock mounting. Worth knowing before anyone plans around either: the printed
cage is not in any manual, and the five stock positions are free.

---

**Tower has more than one cage.** Bay numbers are therefore namespaced by a
per-cage letter (`docs/DISK-LABELLING.md` §3), so a bay is `A1`, `B2` and a cable
label reads `I-SATA2→A1`.

| Cage | Description | Arrangement | Type | Bays |
|---|---|---|---|---|
| **A** | Built-in hotswap cage — **primary** | **single column of 4** | **opposed** | `A1`–`A4` |
| ⟨TBD⟩ | ⟨other cages / brackets — enumerate⟩ | ⟨TBD⟩ | ⟨TBD⟩ | |

**Cage A is the primary.** Informal reference resolves to it — "bay 1" said
aloud, or written on a note during a swap, means `A1`. Printed labels stay
qualified regardless.

⚠ **The other cages are unenumerated.** Six of the ten installed disks currently
sit somewhere recorded only as "internal" in §1. Identify them, assign letters,
and give each its arrangement and type.

### Cage A — built-in hotswap

Confirmed 2026-08-07: **single column of four, opposed** (drives pulled from the
front, cables on a backplane behind). Currently holds the four 12 TB disks,
though that is not fixed — a different spinner can occupy a bay if the layout
calls for it.

**Bays run `A1` at the top down to `A4`.** The convention's left-to-right clause
is moot for a single column.

> **This cage is immune to the mirrored-rear problem**, despite being opposed.
> Walking round to the backplane flips left and right; it does not flip top and
> bottom. With one column there is no left/right to confuse, so `A1` is the top
> from either side.

| Bay | Feeding port | Disk |
|---|---|---|
| `A1` | ⟨TBD⟩ | ⟨TBD⟩ |
| `A2` | ⟨TBD⟩ | ⟨TBD⟩ |
| `A3` | ⟨TBD⟩ | ⟨TBD⟩ |
| `A4` | ⟨TBD⟩ | ⟨TBD⟩ |

**Fill the port column by measurement.** Hotswap makes it directly observable,
and it is quicker than tracing:

```sh
dmesg -w                                  # insert into a bay; note which sdX appears
readlink -f /sys/block/sdX/device         # → …/0000:00:1f.2/ata7/… — controller and port
```

If the four 12 TB caddies get labelled first, the insertions are unnecessary:
read each disk's `sdX` from its serial and resolve the controller from sysfs
directly.

---

## 4. Controllers and ports

| Controller | Ports | Speed | Notes |
|---|---|---|---|
| Onboard Intel C204 | 6 | **2× 6Gb/s + 4× 3Gb/s** | Confirmed 2026-08-07. Not six alike. Silkscreened `I-SATA0`…`I-SATA5`. |
| ASM1166 (PCIe) | 6 | 6Gb/s all six | Shares one PCIe link — Gen2 x2 ≈ 1.0 GB/s today, ~1.97 GB/s if it trains Gen3 on the new firmware. Flashed to ECS06 (2021-11-08) on 2026-08-07. |
| ASM1064 (PCIe x1) | 4 | 6Gb/s | ~500 MB/s shared across all four. Slated for removal under the bare-metal layout. |
| ASM1042 (PCIe **x1**, unmeasured) | — | USB3 | Not storage, but **load-bearing**: the C204 is EHCI only, so this card is the machine's only USB3, and the BD-ROM enclosure wants it. x1 is the chip's spec and is *well matched* — PCIe 2.0 x1 ≈ 500 MB/s against USB 3.0's own ~500 MB/s ceiling, so there is no bandwidth to reclaim. ⚠ **May be pulled 2026-08-08** for a slot cooler beside the LSI; a x1 riser relocates it instead and is the preferred endgame (`PLATFORM.md` §7b). ⟨Confirm `LnkCap`/`LnkSta`; never read on this machine.⟩ |

### Measured device-to-port mapping (sysfs, 2026-08-07)

`readlink -f /sys/block/sdX/device` on the live machine. **Two controllers are
in use; the ASM1166 carries nothing** and does not appear (it was pulled for the
firmware flash and had only the BD-ROM before that).

| `sdX` | Disk | PCI path | Controller | Port |
|---|---|---|---|---|
| `sdb` | `s-3255` Cache | `00:1f.2` | onboard | `ata1` |
| `sdc` | `s-9545` Fastservices | `00:1f.2` | onboard | `ata2` |
| `sdd` | `h-HJDH` **parity-2** | `00:1f.2` | onboard | `ata3` |
| `sde` | `h-X4WE` **parity** | `00:1f.2` | onboard | `ata4` |
| `sdf` | `h-T97E` **disk-1** | `00:1f.2` | onboard | `ata5` |
| `sdg` | `h-NS3Y` **disk-2** | `00:1f.2` | onboard | `ata6` |
| `sdh` | `s-768C` Services 1 | `00:1c.0 → 02:00.0` | **ASM1064** | `ata7` |
| `sdi` | `s-8162` Services 2 | `00:1c.0 → 02:00.0` | **ASM1064** | `ata8` |
| `sdj` | `s-3100` MX100 (unassigned) | `00:1c.0 → 02:00.0` | **ASM1064** | `ata9` |
| `sdk` | `s-5509` Kingston | `00:1c.0 → 02:00.0` | **ASM1064** | `ata10` |

The ASM1064 sits behind PCH root port `00:1c.0` at `02:00.0`. Note the address
differs from what earlier VFIO-era notes recorded — **which is the documented
reason the fleet binds PCI devices by vendor:device ID rather than by address.**

> ⭐ **That reasoning got a second, cleaner demonstration on 2026-08-09.** Adding
> the LSI to a slot renumbered the ASM1064 from `02:00.0` to **`04:00.0`**, because
> the LSI took `02:00.0`. Nothing about the ASM1064 changed — a card was added
> somewhere else in the machine. **And every `sdX` letter shifted by one** as the
> LSI's disk claimed `sda`: the cache SSD moved `sdb`→`sdc`, parity-2 `sdd`→`sde`,
> and so on down the table above. Identities were re-confirmed by serial, and the
> mapping otherwise holds exactly. Bind by ID, never by address or by letter.

### Slot electrical widths — measured 2026-08-09

`lspci -vv` `LnkCap`/`LnkSta` during the §7b cold pass, which closes the gap this
section previously flagged as never read on this machine.

| Root port | Electrical | Max speed | Occupant, 2026-08-09 |
|---|---|---|---|
| `00:01.0` | **x8** | 8 GT/s (Gen3) | untrained — `Width x0` |
| `00:01.1` | **x8** | 8 GT/s (Gen3) | **LSI SAS2008**, negotiated **Gen2 x8** |
| `00:06.0` | **x4** | 5 GT/s (Gen2) | untrained — `Width x0` |
| `00:1c.0` | x1 (PCH) | 5 GT/s | **ASM1064**, Gen2 x1 (`LnkCap` 8 GT/s, capped by the port) |
| `00:1c.4` | x1 (PCH) | 5 GT/s | onboard 82574L NIC, 2.5 GT/s x1 |

**The two x8 slots come off the CPU and are Gen3-capable**; `00:06.0` is a Gen2 x4.
So the LSI is in the right kind of slot and is not slot-limited — a SAS2008 is a
Gen2 part, so `Gen2 x8` is its ceiling, not a downgrade.

⚠ **`00:01.0` and `00:06.0` reporting `Width x0` is a signal, not just an empty
slot.** `PLATFORM.md` §10 records that this board hides root ports with nothing
behind them, so a port that is *visible but untrained* suggests a card present and
failing to link — which is the ASM1166's §1 signature. It was in a slot for this
run and did not enumerate. See `PLATFORM.md` §6e; that result is confounded and
is not yet a verdict on the card.

### ✅ The current cabling is already the bare-metal optimum — do not re-run it

`ata1`/`ata2` are the C204's two **6 Gb/s** ports and `ata3`–`ata6` its four
**3 Gb/s** ports. So the machine as wired today puts:

- **both SSDs on the two fast ports**, where SATA 3.0 is worth having, and
- **all four 12 TB spinners on the slow ports**, where SATA 2.0's ~275 MB/s still
  clears their ~250 MB/s peak with room (`PLATFORM.md` §8).

That is exactly the placement the bare-metal design argues for, arrived at
independently. **The array needs no recabling to move to NixOS** — a step the
retired VFIO plan required, and one of the more disruptive ones. Only the
ASM1064's four devices are in play, and three of those four are being retired or
relocated anyway.

⚠ This also confirms the port budget is *currently* full at ten devices across
two controllers, with the ASM1166's six ports entirely spare.

### ⚠ The slot widths are the real unknown, and `lspci` cannot tell you

`PLATFORM.md` §10 records **four PCIe slots, visually confirmed identical** — but
that is the *physical* connector. Their **electrical** widths are not recorded
anywhere, and on this board they cannot be discovered by inspection: Supermicro
hides root ports with nothing behind them, so an **empty slot does not appear in
`lspci` at all**. Populate it or read the manual; there is no third option.

That gap is newly load-bearing. `DESIGN.md` §6.7 may add an **x8** LSI HBA, and
§5.5 already wants an **x4** NVMe adapter — so slot assignment now matters, and a
**x1 card sitting in the widest slot would waste it**. The ASM1042 is the x1 card;
put it in whichever slot is electrically narrowest.

Read what is actually negotiated, per card:

```sh
# LnkCap = what the card is capable of; LnkSta = what it negotiated in this slot
for d in $(lspci -D -d 1b21: | cut -d' ' -f1); do
  echo "== $d"; sudo lspci -vvs "$d" | grep -E "LnkCap:|LnkSta:"
done
```

⚠ **`LnkCap` settles the card, `LnkSta` settles the pairing.** A card reporting
`LnkCap … x1` is x1 no matter which slot it occupies — so a narrow `LnkSta` is
only evidence about the *slot* when `LnkCap` is wider.

**Port budget is 12** with the ASM1064 removed (onboard 6 + ASM1166 6), against 12
devices under the bare-metal layout. Zero headroom. See `DESIGN.md` §5.5.

⚠ **The `ata` column above only works for onboard AHCI ports.** If the LSI HBA
(`PLATFORM.md` §7b) goes in, its disks arrive via `mpt3sas` as SCSI devices with
no `ataN` equivalent — start from `lsblk -S -o NAME,HCTL,SERIAL,MODEL` and
establish the mapping empirically. Its cable leads label as `0P1`…`1P4` per
`docs/DISK-LABELLING.md` §3.

**The ASM1166 has no silkscreen port numbers.** If cables run to it, assign a
convention — likely counting from the bracket end — and record it here.

### Optical

The BD-ROM moves to an **external USB3 enclosure** and does not return to SATA.
That frees the SATA port the port budget above depends on, so it is not optional.

⚠ The C204 has no USB3 of its own — it exists on this machine only via the
ASM1042 add-in card (`PLATFORM.md` §10). On an onboard port the enclosure runs at
USB2, roughly 35 MB/s against a BD-ROM's ~54 MB/s at 12x: fine for playback,
mildly slower for ripping.

---

## 5. Label strings

### Caddy labels — ready to print

```
h-HJDH
h-X4WE
h-T97E
h-NS3Y
s-3255
s-9545
s-768C
s-8162
s-3100
```

`s-5509` omitted — retiring. `m2-140B` takes no physical label. Drawer disks are
pending serials, in `docs/DISK-DRAWER.md`.

### Cable and bay labels — pending

Bay numbering is settled (§3); these are blocked only on the **port-to-bay
mapping**, which is a measurement rather than a decision. Form is `<port>→<bay>`,
printed twice per cable:

```
I-SATA?→A1
I-SATA?→A2
I-SATA?→A3
I-SATA?→A4
```

Bay labels (`A1`…`A4`) only if the cage does not already carry printed numbers.
The other cages need enumerating before their cables can be labelled at all.

---

## 6. Machine-readable inventory

```csv
id,form,recording,serial_suffix,serial_full,model,size,location,role,colour,physical_label
h-HJDH,hdd35,cmr,HJDH,8DKUHJDH,HUH721212ALE601,12TB,cage-A,array,,yes
h-X4WE,hdd35,cmr,X4WE,8CJZX4WE,HUH721212ALE601,12TB,cage-A,array,,yes
h-T97E,hdd35,cmr,T97E,8CG7T97E,HUH721212ALE601,12TB,cage-A,array,,yes
h-NS3Y,hdd35,cmr,NS3Y,8DJPNS3Y,HUH721212ALE601,12TB,cage-A,array,,yes
s-3255,ssd25,,3255,244964803255,WD Blue SA510,500GB,internal,cache,,yes
s-9545,ssd25,,9545,19013024009545,SATA SSD,223.6GB,internal,fastservices,,yes
s-768C,ssd25,,768C,2422E8B6768C,Crucial BX500,480GB,internal,pool,,yes
s-8162,ssd25,,8162,2506E9A58162,Crucial BX500,480GB,internal,pool,,yes
s-3100,ssd25,,3100,15090EE23100,Crucial MX100,512GB,internal,unassigned,,yes
s-5509,ssd25,,5509,50026B7239015509,Kingston SH103S3120G,120GB,internal,retiring,,no
m2-140B,m2-nvme,,140B,23049339-090140B,Silicon Power UD90 2230,1TB,pcie-adapter,root,,no
```

**All four 12 TB disks are CMR** — the HGST Ultrastar He12 line is conventional
throughout, so none takes the `-smr` marker (`DISK-LABELLING.md` §1). That is a
model-number lookup, not a measurement; it is the safe direction to be wrong in,
since the marker is only ever added, never assumed away. `recording` is empty for
the SSDs and the NVMe, where the field does not apply.

⚠ Worth knowing because **the drawer is not all CMR**: four of the twelve spares
are shingled (`docs/DISK-DRAWER.md`). If one of these array disks ever fails, the
replacement question is not only "is it big enough" — and at 12 TB nothing in the
drawer is, so the answer is currently no on both counts.

---

## 7. Open items

| Item | Source | Blocks |
|---|---|---|
| ~~Which 12TB is parity / parity-2 / disk-1 / disk-2~~ | ~~Unraid Main tab~~ | **Closed 2026-08-07** — see §1 |
| ~~Confirm the encryption inferences in §2~~ | ~~Unraid Main tab~~ | **Closed 2026-08-07** — all confirmed |
| ~~MX100 / `btrfs device remove missing` state~~ | ~~Unraid~~ | **Closed 2026-08-07** — completed; disk unassigned |
| **Enumerate the non-primary cages** | Case open | Six installed disks recorded only as "internal" |
| **Port-to-bay mapping for cage A** | Hotswap insertion + sysfs | Printing cable labels |
| ~~`s-3100` actual state after the `/mnt/services` btrfs removal~~ | ~~Unraid, `btrfs filesystem show`~~ | **Closed 2026-08-07** — duplicate of the row above; §1 and §2 both carry the answer (unassigned, NTFS, unmounted) |
| Enumerate the other cages — letters, arrangement, type | Eyes | Bay identifiers and cable labels for six of ten disks |
| Port-to-bay mapping | Measure it — hotswap insertion + sysfs, see §3 | All cable labels |
| Which two onboard ports are 6Gb/s | Board manual or silkscreen | Final disk placement |
| ASM1166 port numbering convention | A decision, if cables run there | Any ASM1166 cable labels |

The first three are readable from the running machine. The rest need the case
open, and the natural moment is whichever service window does the recabling.
