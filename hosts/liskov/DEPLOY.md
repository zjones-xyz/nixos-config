# Deploying liskov (Supermicro X9SCM / Xeon E3-1230 v2)

liskov is a minimal NixOS hypervisor whose only job, for now, is running the
existing Unraid 7.3.2 install as a KVM guest with its SATA controllers passed
through — so the approach can be evaluated before any workload moves.

**The guarantee this whole design protects: you can be back on bare-metal Unraid
in five minutes.** Power off, boot the Unraid flash drive, done. Nothing here
modifies the flash drive or its boot entry, and the NixOS install touches only
the Kingston 120GB SSD.

### Companion documents

| File | Answers |
|---|---|
| **`DEPLOY.md`** (this) | *What to do*, in order. Steps, commands, checklists. |
| **`BACKGROUND.md`** | *Why it works.* IOMMU groups and why they cannot be split, ACS override and why not to use it, VFIO vs virtio, q35/OVMF, what Unraid's parity model does to I/O, why this CPU generation matters. Read before the first flash or install if any of the config reads as incantation. |
| **`DECISIONS.md`** | *Why it is this way.* Decision → alternatives → rationale, plus what was considered and rejected. Read before changing something that looks arbitrary. |

---

## 0. Read this before touching the BIOS

### The ASM1166 disappearing act

The ASM1166 SATA card is **completely invisible** — no POST banner, absent from
`lspci` entirely — unless **both** of these are set under
*Advanced → Integrated IO Configuration*:

| Setting | Value |
|---|---|
| `PCI Express Port - Gen X` | **Gen2** — explicitly, not `Auto` |
| `Detect Non-Compliance Device` | **Enabled** |

`Auto` fails because the slot is Gen3-capable and the card cannot train at Gen3.

**A CMOS clear or a dead coin-cell resets both and makes the card vanish.** It
looks exactly like hardware failure. If the array's disks are suddenly missing,
check this before suspecting the card, the cables, or the drives.

This board is from 2011, so that coin cell is a live risk rather than a
hypothetical — it is why §2a replaces it up front, before this becomes a 3am
diagnosis.

### Driving the box remotely

FreeIPMI, not ipmitool. Run these from a machine that is *not* Tower:

```sh
ipmiconsole -h 192.168.8.191 -u ADMIN -P              # serial-over-LAN console
ipmipower   -h 192.168.8.191 -u ADMIN -P --stat       # --off / --reset also
```

`-p` and `-P` collide in FreeIPMI's argument parsing — use `-P` alone and let it
prompt. `ipmi-config` whole-file commits fail on this BMC; use minimal
section-only files, and note that `--section` does **not** scope `--commit`.

---

## 1. Blocking prerequisites

Do not start the install until all of these are true.

- [ ] **Flash backup taken and verified restorable.** Non-negotiable. This is
      the licence and the array configuration.
- [ ] **`btrfs device remove missing /mnt/services` confirmed complete**, and the
      MX100 512GB's actual health established. Nothing in this plan depends on
      that drive, but you do not want it failing mid-evaluation and muddying the
      signal.
- [ ] **CMOS battery replaced and ASM1166 firmware updated**, per §2 — both
      before the baseline in §4, for the reason given there.
- [ ] **Recabled** per §3.
- [ ] **Bare-metal parity check passed** after recabling, per §4.
- [ ] **Power-restore behaviour reconciled** — BIOS says `Restore on AC Power
      Loss = Power On`, the BMC reports "Always off", and the machine did not
      autoboot after a full drain. Settle which is authoritative before relying
      on unattended recovery. **Try the CMOS battery first** (§2) — settings not
      surviving a full power drain is the textbook weak-battery symptom, and
      this board is old enough that it is the leading hypothesis.

---

## 2. Before recabling: CMOS battery and ASM1166 firmware

Both belong in the same service window, and both must happen **before the §4
baseline parity check** — not after.

The sequencing is not cosmetic. Firmware affects ASPM, PCIe link behaviour and
stability, all of which move throughput. Baseline on old firmware, then flash,
and the number in §4 describes a machine that no longer exists — which silently
corrupts the virtualized comparison that is the entire point of the exercise.

### 2a. CMOS battery

This board is from 2011. The battery is very likely original.

Read §0 again with that in mind: **a dead coin cell makes the ASM1166 vanish**,
because it wipes the two settings the card needs to be visible at all. That is
the single most confusing failure mode in this document — the array disappears
and it looks like a dead controller — and right now it is sitting under the
whole project as a latent fault waiting for the worst possible moment.

A CR2032 costs about a pound. Replace it.

It may also close out a currently-open question. Prerequisite §1 records that the
BIOS claims `Restore on AC Power Loss = Power On` while the BMC reports "Always
off", and the machine did not autoboot after a full drain. **Settings not
persisting across a full power drain is exactly what a weak CMOS battery looks
like.** Worth resolving that way before hunting for a firmware or BMC
explanation.

⚠ **Replacing the battery clears CMOS.** So it must come *before* re-entering
BIOS settings, and everything in §0 has to be set again afterwards:

- [ ] `PCI Express Port - Gen X` = **Gen2** (explicitly, not Auto)
- [ ] `Detect Non-Compliance Device` = **Enabled**
- [ ] Boot order — Unraid flash ahead of, or trivially selectable against, the
      Kingston (§12)
- [ ] Serial Port Console Redirection — note the unit and baud, they feed
      `boot.kernelParams` in `configuration.nix` (§6)
- [ ] `Restore on AC Power Loss` — and re-test with a full drain

Verify the ASM1166 reappears in `lspci` before going any further.

### 2b. ASM1166 firmware

⚠ **Sources for this section could not be read directly.** Every primary guide
was blocked by egress policy from the session that wrote this, so what follows is
assembled from search summaries. **The commands are unverified — read the linked
guides before running anything.** Links at the end of this section.

**What it buys.** These cards routinely ship with firmware 4–5 years old. The
community-standard fix is to flash the firmware from Silverstone's ECS06 card,
which uses the same chip. Reported gains:

- **ASPM support**, absent on many stock builds, which otherwise blocks the host
  from reaching deep C-states — real idle power on a 24/7 box.
- **Hot-swap**, broken on some stock builds (`221118-0048-00` is specifically
  called out).
- **Stability**, including "link down" flapping traceable to firmware.

**Flash it on pegasus, not this machine.** Three reasons, in order of weight:

1. If it bricks, that happens on a machine which is not holding the array.
2. This board barely enumerates the card at all (§0). Flashing where the card is
   marginal adds a variable to an operation that should be boring.
3. The one documented "card will not appear in the flash tool" platform issue is
   with Intel 600-series and newer. pegasus is AM4/AMD, so it is clear of it.

Check pegasus has a free PCIe slot alongside the 4070 first.

**Tooling.** The mainstream path is `RomUpdWin.exe`, which is Windows-only — and
there is no Windows machine in this fleet. The Linux path is `116xfwdl`,
distributed by Radxa for their hexa-SATA adapter:

```sh
# UNVERIFIED — confirm against the Radxa/Steak guides before running.
sudo ./116xfwdl -S                  # reported to print version info
sudo ./116xfwdl -U 11080000.ROM     # flash
```

`11080000.ROM` is the ECS06 firmware file; the Silverstone package ships it
alongside the Windows tool.

**Two gotchas that come up repeatedly:**

- **Unplug every SATA cable from the card before flashing.** Cards reportedly
  fail to appear in the flash tool with drives attached.
- **CSM may need enabling** in the flashing machine's BIOS for the card to be
  seen.

**Risks.**

- **Some cards have a flash chip the tool cannot write.** This is the
  most-reported failure. It generally fails safe — "will not flash" rather than
  "bricked" — but the update may simply not be available to you.
- **Bricking is possible and no recovery method was found.** The card is cheap;
  the array is not. See "flash it on pegasus" above.
- **ASPM on a 2011 platform can itself cause instability.** Ivy Bridge plus a
  budget controller with newly-enabled power management is exactly the
  combination that produces intermittent dropouts. Watch for it during the §4
  parity check rather than assuming ASPM is free — and note that if you have to
  disable ASPM again afterwards, most of the benefit evaporates.

**A free test worth running afterwards.** The card currently needs Gen2 forced
*and* non-compliance detect (§0), which is a PCIe link-training problem — and
updated firmware is reported to improve link training on older boards. So once
flashed, **set the BIOS back to Auto and see whether the card still enumerates.**
If it does, the §0 landmine is gone for good. Do not count on it; it costs one
reboot to find out.

### 2c. The ASM1064 — recommended NOT to flash

Researched separately rather than assumed to mirror the ASM1166. The conclusion
came out the other way:

- **The headline ASM1064 fix does not apply here.** It is Intel 600-series
  compatibility. This board is Intel C204, from 2011 — not remotely in scope.
- **The other documented ASM1064 firmware finding is a *regression*, not a fix:**
  `221118-0048-00` throws PCIe bus errors when ASPM L1 substates are enabled. L1
  substates are a much later PCIe feature this board almost certainly does not
  implement, so the finding is moot here — but it points the risk in the wrong
  direction.
- **Cross-flashing is community practice, not vendor-sanctioned.** ASM1166
  firmware is *reported* compatible with the ASM1064, which is a bigger leap than
  putting ECS06 firmware on a generic ASM1166 (identical chip). More brick risk
  for less benefit.
- **This controller is temporary anyway** — it returns to the host once the
  Docker workloads migrate (§13).
- **It holds the SSD pools**, which back Docker appdata and are the
  latency-sensitive ones. Destabilising them adds noise to an evaluation that has
  enough variables already.

**Flash it only if it is actually symptomatic** — ATA/UDMA CRC errors, dropouts,
or hot-plug problems traced to it during §4. Otherwise leave it alone.

Unrelated but worth checking while you are in there: the ASM1064 is a PCIe **x1**
controller feeding four SATA ports. On this board's Gen2 slots that is roughly
500 MB/s shared across all four — which a *single* SATA SSD can nearly saturate.
Confirm what it actually negotiates (`lspci -vv` and look for `LnkSta`), because
if those four ports are all SSDs it is a topology bottleneck no firmware will
fix, and it belongs in the §4 baseline notes rather than being mistaken later for
virtualization overhead.

### Sources

Read at least the first two before flashing:
[Phil Barker — Upgrading ASM1166 Firmware for Unraid](https://docs.phil-barker.com/posts/upgrading-ASM1166-firmware-for-unraid/) ·
[Steak's Docs — Updating firmware on ASMedia 106x cards](https://thunderysteak.github.io/upgrading-asmedia-106x-cards) ·
[Win-Raid — Latest Firmware for ASM1064/1166](https://winraid.level1techs.com/t/latest-firmware-for-asm1064-1166-sata-controllers/98543) ·
[Unraid forums — ASM1166/ASM1064 flashen mit der ECS06-Firmware](https://forums.unraid.net/topic/141770-asm1166asm1064-flashen-mit-der-firmware-der-silverstone-ecs06-karte-sata-kontroller/) ·
[Unraid forums — ASM1064: Test der Firmwares](https://forums.unraid.net/topic/185255-asm1064-test-der-firmwares/) ·
[Bennett Piater — Fixing SATA hot plug on an ASM1166 HBA](https://bennett.piater.name/blog/linux/2025/06/13/fixing-asm1166-hba-hot-plug/) ·
[Silverstone ECS06](https://www.silverstonetek.com/en/product/info/expansion-cards/ECS06/) ·
[Internet Archive — ECS06 firmware mirror](https://archive.org/details/ecs-06-firmware-for-intel-600series-chipset)

---

## 3. Recabling

| Controller | Assigned to | Drives |
|---|---|---|
| ASM1166, 6 ports | Guest (permanent) | 4× 12TB HDD + Cache (WD Blue 500GB) + Fastservices (240GB) |
| ASM1064, 4 ports | Guest (**temporary**) | BX500 ×2, MX100 (if healthy), 1 spare |
| Onboard, 6 ports | Host | Kingston 120GB (NixOS root), BD-ROM, 4 spare |

Three moves are easy to miss and each one breaks something specific:

1. **Kingston off the ASM1064 (port 4) → onboard.** The ASM1064 gets bound to
   vfio-pci and handed to the guest. If the host's root disk is still on it, the
   host cannot see its own filesystem.
2. **Cache and Fastservices off onboard (I-SATA 0/1) → ASM1166.** Onboard SATA
   is never passed through, so leaving them there means the guest loses two
   pools.
3. **BD-ROM off the ASM1166 → onboard.** The ASM1166's six ports fill exactly
   with array + cache + fastservices.

Update the drive-to-cage-slot map as drives move. Unraid matches array members by
serial, so slot order is irrelevant *to Unraid* — the physical map is what tells
you which drive to pull when one fails at 3am.

---

## 4. Bare-metal shakedown

**Both controllers get loaded on bare metal before any NixOS work.** Cheap
ASMedia cards behave differently under sustained load than at idle, and you want
any cabling or controller problem to surface while there is exactly one variable
— not tangled up with passthrough debugging later.

⚠ **§2 must be done first — CMOS battery and firmware both.** Firmware changes
ASPM, link behaviour and stability, so a baseline taken on old firmware describes
a machine that will no longer exist by the time you compare against it. Flashing
after this point invalidates the number and there is no way to retake it once the
machine is virtualized.

### 4a. ASM1166 — full parity check

Boot bare-metal Unraid and run a full parity check.

Watch for ATA/UDMA CRC errors in the syslog. Those mean a cable, not a disk.

**This run is the baseline. Write the numbers down** — wall-clock, average MB/s,
peak read — in the table under *§ Performance expectations*. Without them, a
slow virtualized parity check later is ambiguous between "passthrough is costly"
and "the controller was always the limit", and there is no way back to this
measurement once the machine is virtualized.

**Expected bandwidth:** the ASM1166 negotiates Gen2 x2 (~1 GB/s shared) and four
HDDs peak near 800 MB/s. Gigabit networking caps inbound writes around
110 MB/s, so contention is unlikely to show in normal use. The case to watch is
a parity check running concurrently with heavy cache writes.

### 4b. ASM1064 — sustained load test

**A parity check does not touch this card.** It exercises the array, which lives
entirely on the ASM1166. The ASM1064 holds the SSD pools and gets no coverage
from 4a at all — so it needs its own shakedown, and it is arguably the card that
needs it more:

- It is **not getting a firmware update** (§2c), so whatever quirks its shipped
  firmware has, it keeps.
- It backs **Docker appdata**, the latency-sensitive pools — the place where
  problems are most disruptive and least obvious.
- Its **link width is an open question**: a PCIe x1 controller feeding four SATA
  ports is roughly 500 MB/s shared at Gen2, which a single SATA SSD nearly
  saturates. That needs measuring, not assuming, or it will be misread later as
  virtualization overhead.

First, record what the link actually negotiated:

```sh
sudo lspci -vv -d 1b21:1064 | grep -E "LnkCap|LnkSta"
```

Baseline SMART on every drive attached to it. **Attribute 199,
`UDMA_CRC_Error_Count`, is the one that matters** — it counts link and cable
errors specifically, so its delta across the test is the cleanest possible signal
about the controller and cabling rather than the drives:

```sh
for d in /dev/sdX /dev/sdY /dev/sdZ; do
  echo "== $d"
  sudo smartctl -A "$d" | grep -E "UDMA_CRC_Error_Count|Reallocated_Sector"
done
```

Then saturate **all attached drives at once** — the point is to load the shared
x1 link, not each drive in isolation:

```sh
# One per drive, backgrounded, then wait. Run for hours, not minutes: the
# failure mode here is thermal and sustained, not instantaneous.
sudo fio --name=asm1064 --filename=/dev/sdX --rw=read --bs=1M --iodepth=32 \
  --ioengine=libaio --direct=1 --runtime=4h --time_based --group_reporting &
```

> ⚠ **`--rw=read` deliberately.** The BX500s and the MX100 hold live pool data
> and a write test would destroy it. Read-only is sufficient: SATA link CRC
> errors surface on reads exactly as they do on writes, so a read-saturation test
> exercises the controller, the cable and the link — which is what is being
> tested. Only run write tests against the spare port or a drive whose contents
> are genuinely expendable.

Watch the kernel log throughout, in another session:

```sh
dmesg -w | grep -iE "ata[0-9]|link|reset|failed command"
```

**Pass criteria:**

- [ ] `UDMA_CRC_Error_Count` unchanged on every drive — *any* increase means a
      cable or link problem, and it is worth reseating and re-running before
      going further
- [ ] No ATA link resets, "hard resetting link", or failed commands in `dmesg`
- [ ] Aggregate throughput lands near the negotiated link ceiling rather than
      well under it
- [ ] Record the aggregate figure in *§ Performance expectations* — if the x1
      link is the bottleneck, that is a topology fact no firmware or hypervisor
      change will fix, and it needs to be on the record *before* virtualization
      can be blamed for it

If this card misbehaves, that is genuinely useful news: it is temporary hardware
(§13) holding pools that could be relocated, and finding out now costs an
afternoon rather than an evening plus a confusing evaluation.

**New drives get burned in before they are trusted** — the same applies to the
torrent drive in §13. `badblocks -wsv` on a blank drive, or `f3` (already in
serenity's package set), plus a SMART long test.

### 4c. IOMMU and USB survey — do this while the machine is open

Everything in §8 and in `unraid-guest.xml` depends on a topology map that cannot
be derived from a config session. Capture it now:

```sh
./scripts/iommu-survey.sh              # groups + USB controller map
./scripts/iommu-survey.sh /dev/sdX     # ...plus trace one device to its
                                       #   controller, group, and USB identity
```

**Needs `intel_iommu=on`** or `/sys/kernel/iommu_groups` is empty — the script
says so rather than silently reporting nothing. Check `cat /proc/cmdline` first;
if it is missing, add it to Unraid's syslinux append line, reboot, survey, revert.
That touches the boot flag only, not the array.

Two questions to answer while you are in there:

**Which controller is the unused onboard USB2 port behind, and what group is it
in?** Plug a flash drive into that specific port and run the script with its
device node. Note that **a USB device has no IOMMU group of its own** — groups are
a property of PCI devices, so what you are really identifying is the *controller*
behind that port.

**Does moving the ASM1042 to another slot isolate it?** Groups follow slot
topology, not the card, so a different root port may put it in a group of its own
— at which point the host could keep the USB3 controller instead of surrendering
it to group 1. Re-run the survey after any reshuffle; the addresses in
`configuration.nix` and `unraid-guest.xml` are **not** stable across one.

Both feed the licence-key placement decision in §13, which is genuinely open.

---

## 5. Bootloader: UEFI or legacy

`configuration.nix` uses **systemd-boot**, which needs the board in UEFI (or
Dual) boot mode. `disko.nix` also provisions a 1MB BIOS boot partition, so
switching to GRUB later does not mean repartitioning.

Two things to decide before installing:

- **Board boot mode.** If the X9SCM's BIOS revision supports Dual, use it: NixOS
  boots UEFI from the Kingston while the Unraid flash keeps booting legacy
  exactly as it does today. That is the least disruptive option.
- **If the board must stay legacy-only:** replace the `boot.loader.systemd-boot`
  block in `configuration.nix` with
  ```nix
  boot.loader.grub = {
    enable = true;
    device = "/dev/disk/by-id/ata-KINGSTON_<serial>";
  };
  ```
  and drop `boot.loader.efi.canTouchEfiVariables`.

**Unraid flash and UEFI:** the guest boots via OVMF, which needs the flash's
`EFI-` folder renamed to `EFI`. That rename is **safe for the fallback** — it
enables UEFI boot while leaving the syslinux legacy path intact, so the flash
still boots the machine bare metal exactly as before. Verify this on the flash
before first guest start.

---

## 6. Install

Boot a NixOS installer ISO. Everything below is over IPMI SoL or a directly
attached console.

```sh
# 1. Positively identify the Kingston. Do NOT trust /dev/sdX — this machine has
#    three SATA controllers and a dozen drives, and enumeration order varies.
ls -l /dev/disk/by-id/ | grep -i kingston
lsblk -o NAME,SIZE,MODEL,SERIAL

# 2. Put that by-id path into hosts/liskov/disko.nix (replace the
#    ata-KINGSTON_REPLACE_WITH_REAL_SERIAL placeholder), then:
nix run github:nix-community/disko -- --mode disko ./hosts/liskov/disko.nix
```

> ⚠ disko **wipes** whatever `device` points at. Every other drive in this
> machine is a live Unraid array or pool member. Read the path back and confirm
> it is the Kingston before running.

```sh
# 3. Generate hardware config and reconcile it against the checked-in one.
nixos-generate-config --no-filesystems --root /mnt
```

Take the generated `boot.initrd.availableKernelModules` and the **real UUIDs**
into `hosts/liskov/hardware-configuration.nix`. Do not just overwrite that
file — it carries comments explaining why each module is listed, which the
generated one will not.

The single value that must be right for the machine to boot is
`boot.initrd.luks.devices.cryptroot.device`. A wrong UUID drops you to an initrd
rescue shell with no LUKS prompt, which over serial looks identical to a hang.

```sh
blkid -s UUID -o value /dev/disk/by-id/ata-KINGSTON_<serial>-part3
```

Also fix, before installing:

- `hostNic` in `configuration.nix` — confirm with `ip -br link`.
- The serial console unit and baud in `configuration.nix` — confirm in BIOS under
  *Advanced → Serial Port Console Redirection*. Supermicro X9 conventionally uses
  COM2 (`ttyS1`) at 115200, but the BIOS setting is authoritative and a mismatch
  gives you a blank IPMI console that looks exactly like a hang.

```sh
# 4. Install.
nixos-install --flake /mnt/etc/nixos#liskov
```

---

## 7. First boot

Root is LUKS-encrypted from install time, and unlock is **manual over IPMI
serial-over-LAN** for now:

```sh
ipmiconsole -h 192.168.8.191 -u ADMIN -P
# type the passphrase at the cryptsetup prompt
```

Initrd SSH unlock (the `unlock-pegasus` pattern) is deliberately **not** wired up
yet — see the LUKS section of `configuration.nix` for what to add and why it was
deferred. Adding it later is a plain `nixos-rebuild switch`, not a reinstall.
That is the entire reason LUKS goes down at install time rather than after.

---

## 8. Verify passthrough before defining the guest

```sh
# vfio-pci must own all three passed-through ASMedia devices — two SATA
# controllers plus the USB3 card that shares an IOMMU group with one of them...
lspci -nnk | grep -A3 -i '1b21:'
#   → "Kernel driver in use: vfio-pci" on all three:
#       1b21:1166  ASM1166  SATA, 6-port  — array + Cache + Fastservices
#       1b21:1064  ASM1064  SATA, 4-port  — temporary, returns to the host later
#       1b21:1042  ASM1042  USB3          — not storage. It is here only because
#                  IOMMU group 1 holds both it and the ASM1166, and a group is
#                  the indivisible unit of passthrough. Convenient rather than
#                  merely tolerable: the Unraid licence flash drive plugs into
#                  it and keeps its real USB GUID, which is what the licence is
#                  tied to.

# ...and ahci must still own the onboard controller with the root disk.
lspci -nnk -s 00:1f.2

# IOMMU groups formed at all?
for d in /sys/kernel/iommu_groups/*/devices/*; do
  echo "group ${d%%/devices*}: $(basename "$d")"
done | sed 's|/sys/kernel/iommu_groups/||'
```

If `lspci` shows `ahci` on the ASMedia cards instead of `vfio-pci`, the binding
did not take. Check the kernel cmdline actually carries `vfio-pci.ids=`
(`cat /proc/cmdline`) before suspecting hardware — a silently-unapplied binding
presents identically to the BIOS quirk in §0.

---

## 9. Define and start the guest

```sh
sudo virsh --connect qemu:///system define hosts/liskov/unraid-guest.xml
```

Before the first start, edit two things in the live definition
(`sudo virsh edit unraid`):

1. **The MAC address.** Set it to the bare-metal Tower NIC's address so the
   existing DHCP reservation hands the guest the same IP and `tower.internal`
   keeps resolving with no DNS change. This is the single most important line in
   that file — memory-alpha's NFS mounts and NUT client both resolve that name.
2. **The `<hostdev>` bus addresses.** libvirt has no by-ID form for PCI
   passthrough, so those entries reference `01:00.0` / `02:00.0` / `03:00.0`.
   Addresses have been observed to shift on this board — which is exactly why
   the *host* binds by vendor:device ID instead. Re-check with
   `lspci -nn | grep 1b21` and fix if they moved.

Then, deliberately by hand (the domain is not set to autostart, and libvirtd is
configured with `onBoot = "ignore"`):

```sh
sudo virsh start unraid
sudo virsh console unraid       # or the webGUI once it has an address
```

---

## 10. Post-start checklist

- [ ] Unraid boots and **licence is valid** (the flash passed through on the
      ASM1042 keeps its real USB GUID; an emulated USB disk would not).
- [ ] All four pools import: array (4× 12TB), Cache, Fastservices, and the
      ASM1064 pool.
- [ ] Array members are recognised **by serial** — no "new device" prompts.
- [ ] `smartctl -a /dev/sdX` inside the guest returns real SMART data through
      passthrough. If SMART is opaque, the controller is not being passed
      cleanly and long-term health monitoring is blind.
- [ ] Guest reachable at its usual address; `tower.internal` still resolves to
      it.
- [ ] memory-alpha's NFS mounts recover: `/mnt/unmanaged` and
      `/mnt/arr_managed_data`. They are `soft` + `x-systemd.automount`, so
      memory-alpha degrades rather than hangs while Tower is down — but expect
      **Jellyfin's library to go empty during every evaluation window.** Schedule
      around it.
- [ ] Run a parity check *under virtualization* and compare throughput to the
      bare-metal baseline from §4. That comparison is the actual result of this
      experiment. Fill in the table under *§ Performance expectations*, which
      also records what each number was predicted to do and — importantly —
      which shortfalls are expected cost versus a specific, findable fault.

---

## 11. Enrol liskov's sops key

`secrets/liskov.yaml` does not exist yet, and everything in `configuration.nix`
that touches sops is gated on `builtins.pathExists`, so the flake evaluates
cleanly until it does. After first boot:

```sh
ssh-to-age < /etc/ssh/ssh_host_ed25519_key.pub
```

Put that pubkey in `.sops.yaml` replacing the `&liskov` placeholder, add
`*liskov` to the `secrets/liskov\.yaml` creation rule, then:

```sh
sops secrets/liskov.yaml          # create it; add z/hashedPassword
sops updatekeys secrets/liskov.yaml
```

---

## 12. Fallback

At any point: **power off, boot the Unraid flash drive.**

Nothing in this deployment modifies the flash drive or its boot entry. Keep the
flash ahead of — or trivially selectable against — the Kingston in the BIOS boot
order, and **confirm that selection works over IPMI SoL**, since that is how you
will do it when you are not in the room.

The one thing that would compromise this: renaming the flash's `EFI-` folder to
`EFI` for OVMF (§5). That is safe — it adds a UEFI path without removing the
legacy one — but verify the flash still boots bare metal after doing it, before
you need it to.

---

## 13. Deliberately deferred

Not in this deployment, each for a stated reason:

- **Tailscale** — not now.
- **NUT / UPS.** Tower's rack UPS currently USB-attaches to the Unraid box, which
  serves it as `ups@tower.internal` with memory-alpha as a secondary. Under
  virtualization the UPS lands on the host, so the guest can no longer serve it —
  and this host, which physically holds every disk, would have no UPS awareness
  and could get hard-cut mid-parity-check.

  The agreed fix is to **move the UPS to memory-alpha** and make it the NUT
  server, with Tower a client. That is better than making liskov the server,
  because Tower is then a client whether it is running bare-metal Unraid or this
  hypervisor — the arrangement becomes identical in both states and stops being
  something the fallback can break.

  That is a separate `[memory-alpha]` change plus a physical cable move. Until it
  lands, bare-metal Unraid keeps serving its UPS exactly as today, so nothing is
  broken by its absence — but **liskov is unprotected, so treat evaluation as
  attended work.**
- **Virtualizing the licence flash drive** (presenting it as an emulated USB disk
  with a spoofed GUID instead of passing the physical stick through). Wanted
  eventually; deliberately not now, and it buys less than it appears to:

  - It would **not** free the ASM1042 for the host. That card shares IOMMU group
    1 with the ASM1166, which the guest keeps permanently, so the whole group
    goes to the guest whether or not anything is plugged into the USB3 card.
  - It **would** remove the flakiest dependency in the guest boot path — OVMF
    currently has to enumerate the passed-through ASM1042 and find the flash on
    it, which is the most likely reason to end up on the SeaBIOS fallback (§5).
    That is the genuine argument for doing it.
  - It **breaks the five-minute fallback**, which is why it waits. Today falling
    back is "power off, boot the physical flash". If the boot flash is an image
    file on this host's LUKS-encrypted root, falling back means unlocking the
    host, extracting the image, and writing it to a stick. Keeping a physical
    stick in sync as the fallback reintroduces two sources of truth for the
    Unraid config, and they will drift.

  ⚠ **Scope correction (2026-08-06).** This entry is about presenting the licence
  key as an *emulated* USB disk backed by an image file. It is **not** about
  `<hostdev type='usb'>` (QEMU's `usb-host`), which forwards a *real* physical
  device and preserves its descriptors — that works, needs no IOMMU passthrough,
  and is a live option for the licence key. See "Where the licence key lives"
  below. Earlier revisions of `unraid-guest.xml` conflated the two.

  **Verified 2026-08-06: not possible with stock QEMU/libvirt.** Checked against
  QEMU 11.0.2's own device property lists (`-device <model>,help`):

  | model | `serial` | `vendorid`/`productid` |
  |---|---|---|
  | `usb-storage` (emulated) | yes | **none** |
  | `usb-bot` (emulated) | yes | **none** |
  | `usb-uas` (emulated) | yes | **none** |
  | `usb-host` (physical passthrough) | yes | yes |

  Unraid's flash GUID is the vendor:product:serial triple. Every *emulated*
  mass-storage model exposes only `serial` — the VID/PID are fixed to QEMU's
  own values and there is no property to override them. `usb-host` does have
  `vendorid`/`productid`, but those select *which physical device to pass
  through*; they are matchers, not spoofing knobs.

  `<qemu:commandline>` does not rescue this: the limit is the device model, not
  libvirt's XML surface, so dropping to raw QEMU args gains nothing. It would
  take a patched QEMU.

  Also note `<disk>`'s `<vendor>`/`<product>` elements are a red herring — they
  are SCSI INQUIRY strings (max 8 and 16 printable chars, documented for
  scsi-disk/scsi-hd/scsi-cd), not USB descriptor fields. They never reach the
  GUID.

  What this does *not* rule out is `usb-host` device passthrough — see below.

- **Where the licence key lives — OPEN, and worth resolving early.** Two working
  mechanisms; pick deliberately rather than by accident:

  | | Mechanism | Needs a passable IOMMU group? | Licences? |
  |---|---|---|---|
  | today | `<hostdev type='pci'>` of the ASM1042 | yes — and it is only passed at all because group 1 is indivisible | yes |
  | candidate | `<hostdev type='usb'>` (`usb-host`) on the onboard USB2 port | **no** — host keeps the controller | expected yes; forwards real descriptors, supports `bootindex` |
  | ruled out | emulated `<disk bus='usb'>` | n/a | **no** — see above |

  The onboard-USB2 option decouples the licence from any add-in card entirely: no
  slot dependency, and it survives the ASM1042 being moved or removed. It also
  makes the "can the host keep the USB3 controller?" question purely about slot
  choice rather than about licensing.

  **Cheap decisive test, and it does not need liskov to exist.** On pegasus, boot
  any throwaway VM with the Unraid flash attached via `<hostdev type='usb'>` and
  compare `lsusb -v` inside the guest against the host. Matching
  idVendor/idProduct/serial means the GUID is intact and Unraid will licence. That
  settles it in one boot, with nothing at stake.

  Map the ports first with §4c.
- **Beszel** — one less service to debug while proving passthrough.
- **Initrd SSH LUKS unlock** — see §7.
- **Moving the arr stack or download clients out of the guest.** They share one
  `/data` root on one filesystem, so imports are hardlinks and atomic moves.
  Hardlinks do not survive an NFS boundary; relocating them turns every import
  into a full copy. (See `BACKGROUND.md` for why — inodes are filesystem-local.)

  **Planned, deliberately, later: a dedicated torrent drive that accepts the copy.**
  Adding a 2–3TB HDD outside the array for torrent data, with the arr stack
  importing from it into the library, means every import becomes a real copy
  rather than a hardlink. That is a worthwhile trade on Unraid specifically, and
  it is worth being precise about why rather than filing it as a penalty
  reluctantly accepted:

  - **It removes parity write amplification from download churn.** Every write to
    a parity-protected array disk costs read-old-data, read-old-parity, compute,
    write-data, write-parity — four operations per logical write, across two
    spindles. Torrent downloads are exactly the write pattern you least want
    paying that tax.
  - **It stops spending parity on re-downloadable data.** Torrent content is, by
    definition, the most replaceable data on the machine. Protecting it with
    parity is protection bought at the array's expense.
  - **It isolates seeding I/O.** Seeding is constant random reads. Off the array,
    those never contend with parity checks, mover runs, or media playback.

  The copy is paid **once per import**; the parity tax would be paid **on every
  write, forever**. That is the actual shape of the trade.

  Two things to plan around:

  - **Size against seeding retention, not library size.** While seeding, the data
    exists twice — once on the torrent drive, once in the library. The drive's
    capacity sets how long you can seed, which is the number that matters.
  - **Port budget and placement.** The drive must hang off a controller the arr
    stack can reach. While the stack is still inside the guest that means a
    passed-through controller — the ASM1064's spare port is the obvious
    candidate, which is a further reason to be confident in that card (§4b).
    Once Docker migrates to the host and the ASM1064 goes back, it moves to
    onboard SATA instead. Burn the drive in before trusting it (§4b).
- **Auto-unlock for the Unraid array.** Array encryption is unlocked inside the
  guest by Unraid's own machinery and stays manual. A keyfile-on-host-encrypted-
  volume scheme would only *move* the manual step, not remove it.

---

## Performance expectations

Predictions made **before** measuring (2026-08-06), recorded so the result can
falsify them rather than be rationalised after the fact. These are reasoning,
not data — §4's bare-metal run is the data.

### Record measurements here

| Metric | Bare metal (§4) | Virtualized (§10) | Δ |
|---|---|---|---|
| Parity check, wall-clock | | | |
| Parity check, avg MB/s | | | |
| Peak array read MB/s | | | |
| SABnzbd par2 verify, a fixed test set | | | |
| SABnzbd unrar, same set | | | |
| Cache pool (SSD) random read latency | | | |
| Large file write over SMB/NFS, MB/s | | | |
| **ASM1064 aggregate read MB/s** (§4b, all drives at once) | | | |
| **ASM1064 `LnkSta`** (width × speed) | | *n/a* | |
| **`UDMA_CRC_Error_Count` delta**, worst drive | | | |

Use the *same* test set and the same drives for both runs, and run them at
comparable idle. A parity check racing a heavy download is not a comparison.

The three ASM1064 rows serve a different purpose from the rest. They are not a
before/after comparison — they are there to establish, on the record and before
virtualization exists as a suspect, whether that card's PCIe x1 link is a
bottleneck and whether it is electrically clean under load. `LnkSta` has no
virtualized counterpart; the guest sees the controller directly, so the link is
whatever the host negotiated at boot.

### What each number should do, and why

| Dimension | Expectation | Reasoning |
|---|---|---|
| Sequential array throughput | **Within ~0–5%** of bare metal | VFIO gives the guest the controller directly. DMA goes controller → guest memory through the IOMMU: no QEMU block layer, no virtio, no host filesystem in the path. This staying flat *is* the experiment succeeding. |
| Parity check wall-clock | **Roughly unchanged** | Disk-bound, not CPU-bound. XOR across 4 drives at ~800 MB/s is light work for this Xeon. |
| SABnzbd par2 / unrar | **~25% slower** | Genuinely CPU-bound, and the guest has 6 vCPU on 3 physical cores where bare metal had 4. This is arithmetic — cores given away — not virtualization overhead. The change most likely to actually be *felt*. |
| SSD pool latency / jitter | **Modestly worse** | Guest vCPUs are host threads, and this E3 generation predates APICv, so interrupt-heavy paths pay more per interrupt than a modern chip. Shows up on Cache/Fastservices (Docker appdata), not on spinning disks. |
| Network at 1GbE | **Negligible** | virtio-net on a bridge handles ~110 MB/s with minimal CPU. Revisit only at 10GbE. |
| Boot + shutdown | **Longer** | Two OSes plus a LUKS unlock. Operational cost, not throughput. |
| Memory pressure | **Barely different** | 24GB of 32GB, ballooning off. Unraid loses some page cache but the working set dwarfs RAM either way. |

### The ceiling that is not virtualization's fault

The ASM1166 negotiates **Gen2 x2 (~1 GB/s shared across six ports)** and four
12TB drives peak near 800 MB/s combined — so the card is already close to
saturation *on bare metal*. Virtualization does not move that ceiling. The case
to watch is a parity check concurrent with heavy cache writes.

This is exactly why §4 runs first: without that baseline, a slow virtualized
parity check is ambiguous between "passthrough is costly" and "the controller
was always the limit".

### Expected cost vs. something is wrong

A few percent off bare metal is the expected cost. **A 30% shortfall is not** —
that is a specific, findable fault, and worth diagnosing rather than accepting:

- IOMMU not actually in passthrough mode — check `iommu=pt` reached the kernel
  (`cat /proc/cmdline`).
- CPU pins splitting hyperthread siblings. `unraid-guest.xml` assumes the
  conventional layout where cpu0-3 are first threads and cpu4-7 are seconds.
  **Verify with `lscpu -e` before trusting the pinning** — if this box enumerates
  differently, the pins split cores and cost real throughput.
- Interrupt storm or MSI-X not negotiated on a passed-through controller
  (`grep 1b21 -A2 /proc/interrupts`, watch for one CPU pegged in `si`).
- The guest not actually getting the controller — re-run §8.

---

## Routine use

```sh
nrs                                    # nixos-rebuild switch --flake ~/nixos-config#liskov
vfio-check                             # lspci -nnk | grep -A3 -i '1b21:'
unraid list                            # sudo virsh --connect qemu:///system list
unraid-console                         # serial console into the guest
```

Smoke-test config changes without touching Tower — boots the same config under
plain QEMU with the real hardware and VFIO stripped out:

```sh
nix run .#nixosConfigurations.liskov-vm.config.system.build.vm
```

It cannot prove passthrough (there is no ASM1166 in a VM). It proves everything
else: networkd, libvirtd, users, sops gating, serial console.

### When the ASM1064 goes back to the host

Once the Docker workloads migrate off Unraid, handing that controller back is two
deletions:

1. the `"1b21:1064"` line in `homelab.vfio.pciIds` (`configuration.nix`)
2. the matching third `<hostdev>` block in `unraid-guest.xml`

Nothing else references it.
