# liskov — background reading

`DEPLOY.md` says *what to do*. This says *why it works*, so the terse assertions
in `configuration.nix` and `unraid-guest.xml` read as reasoning rather than
incantation. Nothing here is a step to perform.

Written from general knowledge rather than fetched sources — see
[Further reading](#further-reading) for the caveat on link verification.

---

## The IOMMU

Normally a PCI device performing DMA writes straight to physical memory using
addresses the driver hands it. That is fine when the driver is the host kernel,
and catastrophic when it is a guest: a guest handed a real device could point it
at any physical address and read or corrupt host memory.

The IOMMU (Intel calls the feature **VT-d**) sits between devices and RAM and
translates device addresses through page tables the hypervisor controls, exactly
as the MMU does for CPU accesses. A passed-through device can then only reach
memory the hypervisor has mapped for that guest.

This is why `intel_iommu=on` is not optional. Without it there are no
translations, no isolation, and `vfio-pci` has nothing to attach to.

### `iommu=pt`

Passthrough mode. Devices the *host* keeps get an identity mapping — device
address equals physical address — so their DMA skips translation entirely.
Devices assigned to a guest still get real, enforced translation.

The effect is to remove IOMMU overhead from host I/O without weakening guest
isolation, which is why it is a near-universal default on passthrough hosts.

---

## IOMMU groups, and why they cannot be split

A group is the **smallest set of devices the IOMMU can isolate from each other**.
Everything in one group must be assigned together — all to the host, or all to
one guest. There is no partial assignment.

Groups are not arbitrary. They fall out of PCIe topology and a capability called
**ACS** (Access Control Services). Two devices behind the same bridge, where that
bridge does not advertise ACS, can send **peer-to-peer** transactions directly to
each other without the transaction ever reaching the root complex — and therefore
without the IOMMU seeing it. The IOMMU cannot mediate traffic it never observes,
so it cannot claim the two devices are isolated, and it groups them together.

This is precisely the situation on this machine:

```
group 1:  1b21:1166  ASM1166 SATA   (01:00.0)
          1b21:1042  ASM1042 USB3   (02:00.0)
group 9:  1b21:1064  ASM1064 SATA   (03:00.0)
group 8:  8086:....  onboard SATA + LPC bridge
```

The ASM1042 is not passed through because we want it. It is passed through
because **group 1 is indivisible and the ASM1166 must go to the guest.** That the
Unraid licence key happens to live on it is a convenience discovered afterwards,
not the reason.

**Groups follow slot topology, so they are not a fixed property of the cards.**
Move the ASM1042 to a different slot — behind a different root port — and it may
land in its own group, at which point the host could keep it. Any reshuffle
invalidates the map above; re-derive it with `scripts/iommu-survey.sh` rather
than assuming.

Group 8 is the mirror image: onboard SATA shares a group with the LPC bridge, so
passing the SATA controller would mean passing the LPC bridge — which carries the
firmware interface. That is unworkable, and it is why the host's root disk lives
on onboard SATA where nothing can take it.

### ACS override — why not to use it

There is a well-known out-of-tree kernel patch, `pcie_acs_override=`, which makes
the kernel *pretend* devices advertise ACS, splitting groups that are not really
isolable.

It does not add isolation. It suppresses the kernel's report that isolation is
absent. Peer-to-peer DMA between the "split" devices remains possible and remains
invisible to the IOMMU, so a compromised or merely buggy guest can reach the
other device — and through it, potentially host memory. It has never been merged
upstream for exactly this reason.

**It is not needed here.** The groups on this board are already clean for what we
want: the ASM1166 and its group-mate go to the guest, the ASM1064 is isolated on
its own, and onboard SATA stays with the host. If a future change seems to
require ACS override, that is a signal to re-examine the slot layout, not to
apply the patch.

---

## VFIO, and the ordering problem

`vfio-pci` is a stub driver. Its entire job is to claim a device so that no real
driver does, and to expose it through `/dev/vfio/` for a userspace process —
QEMU — to drive.

The subtlety is **timing**. Whichever driver probes a device first owns it. For a
SATA HBA the competitor is `ahci`, which the initrd loads early because it needs
to find the root filesystem. If `ahci` gets there first, it binds the controllers
and passthrough silently does not happen: the guest fails to start, or worse,
starts without its disks.

Two mechanisms, in `modules/nixos/vfio.nix`:

1. **`boot.initrd.kernelModules = [ "vfio_pci" … ]`** force-loads vfio-pci inside
   the initrd, *before* the storage modules. This is the load-bearing one.
2. **`softdep ahci pre: vfio-pci`** in modprobe config covers the booted system,
   where load order is not under the initrd's control.

The binding itself is by **`vfio-pci.ids=` on the kernel command line**, not
`modprobe.d`. The cmdline is parsed by the module at load time and so applies
inside the initrd; `/etc/modprobe.d` is a property of the booted root filesystem
and may not be readable early enough.

> Stale-guide trap: nearly every pre-2023 VFIO tutorial tells you to load
> `vfio_virqfd`. It was folded into `vfio_pci` in Linux 6.2 and no longer exists.
> On a 26.05 kernel, listing it is a missing-module error at initrd build. The
> invariant check in `flake.nix` asserts it is absent.

---

## Why passthrough rather than virtio

The alternative to handing over the controller is to give the guest **virtio-blk**
or **virtio-scsi** disks backed by host block devices or files. Virtio is
*paravirtualised*: the guest knows it is virtual and uses a shared-memory ring
buffer instead of emulating real hardware registers. It is fast — far faster than
emulating an actual SATA controller — and it is the right answer for most guests.

It is the wrong answer here, for reasons specific to Unraid:

- **Every I/O still traverses the host block layer**, adding a scheduler, a page
  cache, and a context switch per request. With passthrough, DMA goes controller
  → guest memory directly, with the IOMMU translating. The host kernel is not in
  the data path at all.
- **SMART and ATA pass-through get filtered.** Unraid needs real device access to
  monitor drive health and to spin disks down. Through virtio it sees a generic
  block device.
- **Unraid identifies array members by serial.** Virtio disks present synthetic
  identifiers, so the array would not recognise its own members.

The trade is that passthrough is all-or-nothing at group granularity, and the
host cannot touch those disks while the guest runs. For a storage appliance
that is the correct trade.

---

## Three ways to get a USB device into a guest

Worth separating, because two of them work for an Unraid licence key and one does
not — and conflating them is easy.

**1. Emulated storage — `<disk bus='usb'>`, QEMU's `usb-storage`.** A file or
block device on the host, presented to the guest as a USB disk. The guest sees a
device QEMU invented. `usb-storage` exposes a settable `serial` and *nothing
else* — there is no property for `idVendor` or `idProduct`. Since the Unraid GUID
is built from vendor:product:serial, two thirds of it are pinned to QEMU's own
values and the GUID cannot be reproduced. **This is the one that cannot license**,
and no amount of `<qemu:commandline>` fixes it, because the limitation is the
device model rather than libvirt's XML surface.

**2. Device passthrough — `<hostdev type='usb'>`, QEMU's `usb-host`.** A *real*
physical device, claimed from the host and proxied to the guest. Its
`vendorid`/`productid`/`serial` properties are **selectors** — they choose which
device to grab — and the descriptors the guest sees are the device's own,
forwarded. So the GUID survives. It also supports `bootindex`, so guest firmware
can boot from it.

Crucially, **this does not involve the IOMMU at all.** The host keeps the
controller; QEMU forwards one device on it. So the controller's IOMMU group is
irrelevant, which makes this the flexible option: any USB port on the machine
becomes a candidate, including onboard ones sharing a group with half the
chipset.

**3. Controller passthrough — `<hostdev type='pci'>` of the USB controller.** The
guest owns the whole controller and every port on it, via VFIO. Requires the
controller to sit in a passable IOMMU group. Strongest isolation, least
flexibility — and on this machine it is what happens to the ASM1042 as a *side
effect* of group 1, not as a deliberate choice about the licence key.

The practical consequence: where the licence key is plugged in and which slot the
ASM1042 occupies are **independent decisions**. Option 2 decouples them entirely.

---

## q35 and OVMF

Two independent choices that are usually made together.

**Machine type — q35 vs i440fx.** i440fx emulates a 1996 PCI chipset; every
device lands on a flat PCI bus. q35 emulates an ICH9-era platform with a real
PCIe hierarchy: root ports, express capabilities, the lot. Passed-through PCIe
devices expect to sit behind a PCIe root port and to have their express
capability registers work. On i440fx they are presented as legacy PCI devices,
which mostly works and then intermittently does not. With three controllers being
handed over, q35 is the conservative choice.

**Firmware — OVMF vs SeaBIOS.** SeaBIOS is a legacy BIOS implementation; OVMF is
UEFI, built from TianoCore EDK2. OVMF is the better fit for q35 and handles PCIe
enumeration more predictably.

The wrinkle is that Unraid's flash drive ships legacy/syslinux-bootable, so it
needs its `EFI-` folder renamed to `EFI` for UEFI. That rename is additive — it
leaves the syslinux path intact — so the bare-metal fallback survives it. If OVMF
cannot enumerate the flash through the passed-through USB3 controller (a
known-finicky combination), SeaBIOS + i440fx is the documented retreat.

As of nixpkgs 26.05, OVMF images ship with QEMU by default and the old
`virtualisation.libvirtd.qemu.ovmf` option is *removed* — setting it trips an
assertion. This is what lets `unraid-guest.xml` use libvirt's `firmware='efi'`
autoselection rather than a hardcoded `/nix/store` loader path that the next
nixpkgs bump would invalidate.

---

## What Unraid's parity model does to I/O

Worth understanding because it shapes every performance expectation in
`DEPLOY.md`.

Unraid is not RAID. Each data disk carries an independent filesystem, readable on
its own in any Linux box, and parity is computed **across** disks at the block
level. A single parity disk protects against one drive failure; it must be at
least as large as the largest data disk.

Two consequences:

**Writes are expensive.** Updating one block means read the old data block, read
the old parity block, compute new parity, write data, write parity — four
operations for one logical write, spread across two spindles. This is why Unraid
leans so heavily on a cache pool: writes land on SSD and are moved to the array
later, out of the interactive path.

**Parity checks read everything, in parallel, sequentially.** All disks stream at
once for hours. This is the single most demanding thing the storage stack ever
does, and it is why it is the chosen benchmark in `DEPLOY.md §4` — it saturates
the controller link, exercises every cable, and is CPU-light enough that any
shortfall points at I/O rather than compute.

It is also why the ASM1166's **Gen2 x2 (~1 GB/s shared)** link is the ceiling
worth knowing about: four 12TB drives streaming together approach 800 MB/s, so
the card is near saturation *on bare metal*, before virtualization enters the
picture at all.

---

## Why this CPU generation matters

The Xeon E3-1230 v2 is Ivy Bridge, 2012. Hardware virtualization (VT-x) and VT-d
are both present and mature, so the fundamentals are fine.

What it lacks is **APICv** — virtual interrupt delivery — which arrived on
Ivy Bridge-EP (Xeon E5 v2) and Haswell. Without it, interrupt delivery to a guest
requires a VM exit into the hypervisor rather than being handled by hardware. The
cost is small per interrupt and invisible on throughput-bound work, but it shows
up as **jitter on latency-sensitive, interrupt-heavy paths** — which in this
deployment means the SSD pools backing Docker appdata, not the spinning array.

This is the concrete reason `DEPLOY.md`'s performance table predicts "modestly
worse latency" while predicting flat sequential throughput. Different mechanisms,
different exposure.

---

## Two smaller things worth knowing

**Why the arr stack cannot move across NFS.** A hardlink is a second directory
entry pointing at the same inode *within one filesystem*. Inodes are
filesystem-local, so a hardlink can never span a filesystem boundary — and an NFS
export is a boundary. The arr apps and download clients share one `/data` root
specifically so that an import is a hardlink (instant, no extra space) and a move
is atomic. Split them across an NFS boundary and every import silently becomes a
full byte-for-byte copy. That is why `DEPLOY.md §13` refuses to relocate them.

**Why the initrd needs its own SSH host key.** The initrd runs *before* the root
filesystem is unlocked, so it cannot read anything stored on it — including the
real host key, and including any sops secret, since the sops age identity *is*
the host key. The remote-unlock setup on memory-alpha and pegasus therefore uses
a dedicated, deliberately unencrypted key at `/etc/secrets/initrd/`. It is a
chicken-and-egg problem, not an oversight, and it is worth understanding before
wiring the same thing up here.

---

## Further reading

⚠ **Verification caveat.** The session that wrote this could not fetch external
pages — egress policy blocked every host attempted, including several of the
links below. These are citations gathered from search results, **not sources
whose contents were read and checked.** Treat them as starting points.

### VFIO and IOMMU

- **Arch Wiki — PCI passthrough via OVMF.** The de facto reference. Practical,
  current, and the best single explanation of group enumeration and the ACS
  override trade-off.
  <https://wiki.archlinux.org/title/PCI_passthrough_via_OVMF>
- **Kernel documentation — VFIO.** Primary source for the driver's model and the
  group/container abstraction.
  <https://docs.kernel.org/driver-api/vfio.html>
- **Alex Williamson's blog (VFIO maintainer).** The IOMMU-groups and ACS posts
  are where most secondhand explanations, including this one, ultimately trace.
  <https://vfio.blogspot.com/>

### libvirt / QEMU

- **libvirt domain XML format.** Authoritative for `unraid-guest.xml`. Note that
  `<disk>`'s `<vendor>`/`<product>` are SCSI INQUIRY strings, not USB descriptor
  fields — a distinction that closed out the licence-flash question in
  `DEPLOY.md §13`. (libvirt.org 403s from some networks; the mirror works.)
  <https://libvirt.org/formatdomain.html> ·
  mirror: <https://avdv.github.io/libvirt/formatdomain.html>
- **QEMU device properties**, best read from the binary rather than the web —
  this is how the licence-flash question was actually settled:
  `qemu-system-x86_64 -device usb-storage,help`

### Unraid specifics

- **Unraid docs — parity and the array.** For the write-amplification and
  parity-check behaviour described above.
  <https://docs.unraid.net/unraid-os/manual/storage-management/>
- **Unraid forums — virtualizing Unraid.** Community practice varies in quality;
  the useful threads are the ones passing HBAs through, not those emulating
  disks.

### Hardware

- **ASMedia firmware guides** — see the annotated list at the end of
  `DEPLOY.md §2`, which carries the same verification caveat.
- **Supermicro X9SCM manual** — for the Integrated IO Configuration settings that
  make the ASM1166 visible at all (`DEPLOY.md §0`).

### Theory, if you want it

- **Popek & Goldberg (1974), "Formal Requirements for Virtualizable Third
  Generation Architectures."** The paper that defines what a hypervisor *is* —
  equivalence, resource control, efficiency. Short, readable, and the origin of
  the framing behind this host's name.
- **Liskov & Wing (1994), "A Behavioral Notion of Subtyping."** The substitution
  principle stated precisely. The host is named for it because that is exactly
  the contract being tested: Unraid must not be able to tell it is not on bare
  metal.
