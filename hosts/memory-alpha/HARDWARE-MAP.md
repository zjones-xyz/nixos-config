# memory-alpha — hardware map

Disks installed in this machine, its controllers and cabling.

Naming and labelling rules are fleet-wide and live in `docs/DISK-LABELLING.md`.
Unassigned spare disks live in `docs/DISK-DRAWER.md`.

**This is a short file, and honestly so.** memory-alpha is single-NVMe: one disk,
three partitions, nothing to trace and nothing to label. It exists for the same
reason `hosts/pegasus/HARDWARE-MAP.md` does — so "what is in this machine" has an
answer that does not require SSHing into it — and because §2 records a
configuration defect that `lsblk` made visible, and how it was fixed.

Dates are UTC.

---

## 1. Installed disks

**Read from `lsblk -o NAME,SIZE,MODEL,SERIAL,TYPE,FSTYPE,MOUNTPOINT`, 2026-08-08**,
on NixOS generation 36 (rev `0c6229f`).

| ID | Device | Size | Full serial | Role | FS | Enc. |
|---|---|---|---|---|---|---|
| `m2-0590` | **PNY CS2130 1TB SSD** | 1 TB | `PNY21232106090100590` | **Root** | LUKS → btrfs | **yes** |

| Partition | Size | Contents |
|---|---|---|
| `nvme0n1p1` | 1 GB | vfat ESP → `/boot` (UUID `2119-813F`) |
| `nvme0n1p2` | 921.7 GB | LUKS `21aed1d9-…` → btrfs, subvols `/`, `/home`, `/nix` |
| `nvme0n1p3` | 8.8 GB | LUKS `60b43e2c-…` → **declared as swap, not open** — see §2 |

**One disk means no physical labels.** M.2 cards take none
(`DISK-LABELLING.md` §2), and with a single device there is nothing to
disambiguate anyway. The identifier is for inventory only.

⚠ **No spare capacity and no second disk.** Worth stating plainly because
`hosts/galactica/DESIGN.md` §6.6 makes this host the **restore target for the
borgmatic pilot** — restoring `partdb` and its paired appdata here needs free
space on the one root filesystem, and nobody has checked how much there is.
⟨`df -h /` settles it.⟩

---

## 2. ⚠ Encrypted swap was declared but never opened — fixed, not yet deployed

**`swapDevices` points at a device mapper node that nothing creates.**

```nix
# hosts/memory-alpha/hardware-configuration.nix:41
swapDevices =
  [ { device = "/dev/mapper/luks-60b43e2c-62be-4e50-b590-190241219796"; }
  ];
```

There is **no `boot.initrd.luks.devices` entry for `60b43e2c`** anywhere in the
repo — only the root's `21aed1d9` (line 21) — and no `crypttab`. So the mapper is
never opened and the swap unit has nothing to attach to.

**`lsblk` confirms it empirically rather than by inference:** `nvme0n1p2` shows its
`crypt` child, and `nvme0n1p3` shows none. The container is closed on a running
system.

**So memory-alpha almost certainly has no swap at all.** It has no zram either —
`modules/nixos/performance.nix` provides that, and it is a pegasus module this
host does not import. Confirm in one command:

```sh
swapon --show && free -h
```

### Why it happened

`nixos-generate-config` writes `swapDevices` from what is *mounted at generate
time*, but only emits `boot.initrd.luks.devices` for containers needed to reach
the **root** filesystem. An encrypted swap partition therefore lands in the
generated config as a mapper path with no opener behind it. It is a known sharp
edge of the installer, not a mistake anyone made by hand — which is exactly why it
survived to generation 36 unnoticed.

### Why it matters here specifically

This is not a cosmetic 8.8 GB. **memory-alpha is the fleet's aarch64 build host** —
`flake.nix` routes hopper and hamilton deploys through it via binfmt QEMU
emulation, and building an SD image under emulation is memory-hungry and bursty.
That is precisely the workload where a missing swap turns into an OOM kill rather
than a slow build. It is also the borgmatic pilot's restore target (§1).

### Fixing it — three options, and the middle one is probably right

| Option | Cost |
|---|---|
| Declare the LUKS device in initrd | Restores the 8.8 GB, but adds a **second passphrase prompt** to every boot — and this host's whole remote-unlock design (`configuration.nix` §LUKS SSH unlock) is built around one |
| **Random-key encrypted swap** on the raw partition | `randomEncryption.enable = true` — fresh key each boot, no passphrase, no key management. ⚠ Breaks hibernation, which is irrelevant on a headless server. Discards the existing LUKS header, which costs nothing since swap contents are worthless by definition |
| zram instead, drop the partition | Matches pegasus and Tower (`SHARES.md` §5 notes Tower runs `zram1` at 15.7 G). Compressed in-RAM swap. ⚠ Does not help the case that matters here — under emulation-driven memory pressure, zram competes for the same RAM |

**Fixed in #43**, merged 2026-08-09 — the middle option above. `swapDevices` now
points at the raw partition with `randomEncryption.enable = true`. The device path
was derived from the disk's model and serial, so it was checked against the host
before merge rather than trusted: `/dev/disk/by-id/nvme-PNY_CS2130_1TB_SSD_PNY21232106090100590-part3`
resolves to `nvme0n1p3`, the same partition this section caught sitting idle.

⚠ **Merged is not deployed.** The config is on `main`; this host still has no
active swap until someone rebuilds it, because every `switch` happens on the
target host (`CLAUDE.md` §Workflow). First activation `mkswap`s the partition,
overwriting the stale `60b43e2c` LUKS header — free, since swap contents are
worthless by definition. Confirm with the same command that exposed the defect:

```sh
swapon --show && free -h
```

---

## 3. Encryption

**The whole disk is encrypted apart from the ESP**, which cannot be. Root, `/home`
and `/nix` are btrfs subvolumes inside LUKS `21aed1d9-…`; the swap partition holds
a stale second LUKS container, superseded by random-key encrypted swap in #43 and
rekeyed from `/dev/urandom` on every boot once this host is rebuilt (§2).

**LUKS unlock is available pre-boot over SSH.** A tiny SSH server runs in the
initrd before the root is decrypted, over MAC-pinned interface names so the
dongles keep their identities across replugs. `configuration.nix` documents the
sequence, including the chime unit that fires once unlock completes.

---

## 4. Controllers, ports and network

### The board — a Framework Laptop 13 Gen 1 mainboard in a printed case

**Owner-confirmed 2026-08-30**, closing this section's two standing ⟨unknowns⟩.
Gen 1 means **11th-generation Intel Tiger Lake** (UP3) — one of `i5-1135G7`,
`i7-1165G7` or `i7-1185G7`, all 4C/8T with Iris Xe graphics. ⟨Exact SKU still
unread; one `lscpu` settles it.⟩

⚠ **This fact had been living in the wrong file.** The only prior record of the
CPU generation anywhere in the tree was a *comment* in
`modules/nixos/jellyfin.nix` — `intel-media-driver # iHD — required for 11th-gen
(Tiger Lake) Quick Sync` — which is fine as corroboration and useless to anyone
asking "what is this machine". It belongs here.

**Everything the config already showed follows from the board:**

| Observation | Explanation |
|---|---|
| `thunderbolt` in initrd modules | The four expansion-card slots are USB4/Thunderbolt-capable |
| No `ahci` anywhere | The board has **no SATA** at all |
| 32 GB RAM (§2's `free -h`) | Two DDR4 SO-DIMM slots, 2× 16 GB |
| Ethernet over USB-C dongles | ⭐ **Framework has no onboard NIC.** See below |

⭐ **One M.2 2280 socket, and that is the entire complement.** So §1's "no spare
capacity and no second disk" is **structural, not incidental** — there is nowhere
to add a disk without replacing the one that is there. That matters directly:
`hosts/galactica/DESIGN.md` §6.6 makes this host the borgmatic pilot's restore
target, and the restore has to fit on the single root filesystem or not happen.

**Networking is two USB-C Ethernet dongles, not onboard NICs**, and they are
MAC-pinned to stable names because predictable interface names encode the USB
*port path* — replugging a dongle into a different port would otherwise rename it:

| Name | MAC | Role |
|---|---|---|
| `eth-primary` | `6c:1f:f7:bc:55:f5` | what `memory-alpha.internal` resolves to |
| `eth-secondary` | `9c:69:d3:4c:c5:16` | ipvlan parent for the Bambuddy virtual-printer network |

Recorded here because **the MACs are hardware identity in the same sense a disk
serial is** — they are the thing the config pins to, and replacing a dongle means
editing `configuration.nix`.

⚠ **This is not a workaround anyone chose.** A Framework mainboard has no onboard
Ethernet; networking *is* expansion cards, which are USB-C devices. So the
port-path pinning above is structural too — there is no onboard NIC to fall back
to if a dongle misbehaves, and "just use the built-in port" is not advice that
applies to this machine.

### ⚠ Thermal envelope — a mobile part, and the case is not aluminium

**Tiger Lake UP3 is a 15 W nominal part, configurable to 28 W.** It is designed to
be cooled by a laptop: a small blower into a heatsink, with the aluminium chassis
acting as both spreader and thermal mass. This board has the blower and the
heatsink; it does not have the chassis.

✅ **The printed case has deliberate airflow** (owner-confirmed 2026-08-30), so the
blower has a real intake and exhaust path rather than recirculating — which is the
failure mode that would have made sustained load a hard wall. What airflow does
**not** restore is the aluminium's thermal mass, and printed plastics are
insulators: PLA's glass transition is ~60 °C, PETG's ~80 °C, both inside the range
a heat-soaked enclosure can reach.

⚠ **The package budget is contended three ways, not two.** CPU inference, the Xe
iGPU (Quick Sync *or* OpenVINO), and Jellyfin transcoding all draw from the same
15–28 W envelope. They compete for watts even when they are not competing for
`/dev/dri/renderD128`.

⚠ **Nothing in `configuration.nix` manages any of this today** — no
`services.thermald`, no RAPL power caps, no governor configuration. That is
fine for Jellyfin's bursty transcodes, which is all this host has been asked to do.
It is **not** fine for sustained multi-hour load, and that is exactly what is now
being contemplated: `hosts/galactica/DECISIONS.md` §9's Immich rebuild would put a
days-long ML import here, on the strength of this board having **AVX-512 VNNI and
an iGPU** against galactica's 2012 Xeon having neither.

⭐ **For sustained work, cap PL1 rather than letting it boost.** Counter-intuitive
but reliable on mobile silicon in a marginal enclosure: holding ~15 W for eight
hours beats reaching 28 W for twenty minutes and then heat-soaking down to single
digits. Total throughput is higher and the case stays well away from its glass
transition. `services.thermald.enable` is the standard NixOS lever;
`/sys/class/powercap/intel-rapl` is the explicit one.

---

## 5. Machine-readable inventory

```csv
id,form,recording,serial_suffix,serial_full,model,size,location,role,colour,physical_label
m2-0590,m2-nvme,,0590,PNY21232106090100590,PNY CS2130 1TB SSD,1TB,m2-slot,root,,no
```

`recording` does not apply to an NVMe. `physical_label` is `no` — M.2 cards take
none, and there is no second disk to confuse it with.

⚠ Note pegasus also runs a PNY NVMe (`m2-0257`, a CS3250 2TB) with a
similarly-shaped serial. The four-character suffixes differ, and
`DISK-LABELLING.md` §1 records that cross-host collisions are harmless in any
case — the labels never meet.

---

## 6. Open items

| Item | Source | Blocks |
|---|---|---|
| ⚠ **Swap never activates** | `swapon --show` to confirm, then a `.nix` PR | aarch64 builds under memory pressure; §2 |
| **Free space on `/`** | `df -h /` | Sizing the borgmatic pilot restore (`DESIGN.md` §6.6) |
| ~~Board model, chassis, whether a second M.2 exists~~ | **Closed 2026-08-30** — Framework Laptop 13 Gen 1 mainboard, printed case, one M.2 2280 socket and no second (§4) | — |
| **Exact CPU SKU** — `i5-1135G7` / `i7-1165G7` / `i7-1185G7` | `lscpu` | Nothing today; wanted before sizing the Immich ML import (§4) |
| ⚠ **Sustained thermal behaviour under multi-hour load** | Watch package temp through the first hour of a long job | Whether the Immich ML import runs here at all (§4, `galactica/DECISIONS.md` §9) |
| Whether this host should run zram regardless | A decision | §2, and consistency with pegasus/Tower |

The first is the only one that is a defect rather than a gap. It has been latent
since install and is cheap to fix; it just needs its own branch.
