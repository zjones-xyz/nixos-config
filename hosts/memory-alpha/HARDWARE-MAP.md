# memory-alpha — hardware map

Disks installed in this machine, its controllers and cabling.

Naming and labelling rules are fleet-wide and live in `docs/DISK-LABELLING.md`.
Unassigned spare disks live in `docs/DISK-DRAWER.md`.

**This is a short file, and honestly so.** memory-alpha is single-NVMe: one disk,
three partitions, nothing to trace and nothing to label. It exists for the same
reason `hosts/pegasus/HARDWARE-MAP.md` does — so "what is in this machine" has an
answer that does not require SSHing into it — and because §2 records a live
configuration defect that `lsblk` made visible.

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

## 2. ⚠ Encrypted swap is declared but never opened

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

⚠ **This is a `.nix` change, so it takes a feature branch and a PR**
(`CLAUDE.md` §Workflow) — deliberately not fixed in the same pass that wrote this
file, which is documentation only.

---

## 3. Encryption

**The whole disk is encrypted apart from the ESP**, which cannot be. Root, `/home`
and `/nix` are btrfs subvolumes inside LUKS `21aed1d9-…`; the swap partition is a
second LUKS container that is currently inert (§2).

**LUKS unlock is available pre-boot over SSH.** A tiny SSH server runs in the
initrd before the root is decrypted, over MAC-pinned interface names so the
dongles keep their identities across replugs. `configuration.nix` documents the
sequence, including the chime unit that fires once unlock completes.

---

## 4. Controllers, ports and network

⟨Board and chassis unrecorded.⟩ Intel platform — `kvm-intel`, with `thunderbolt`
and `xhci_pci` in `boot.initrd.availableKernelModules`. One M.2 socket populated;
⟨whether a second exists is unknown⟩.

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
| Board model, chassis, whether a second M.2 exists | Case open | Any future expansion |
| Whether this host should run zram regardless | A decision | §2, and consistency with pegasus/Tower |

The first is the only one that is a defect rather than a gap. It has been latent
since install and is cheap to fix; it just needs its own branch.
