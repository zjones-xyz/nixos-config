# galactica — decision log

Tower's NixOS identity. Each entry: **decision → alternatives → rationale.**

Nothing here has been activated on hardware. There is no `configuration.nix` yet,
deliberately — see *Why there is no config here yet* below.

Companion documents: `DESIGN.md` (what is being built and why), `PLATFORM.md`
(what the machine does), `HARDWARE-MAP.md` (what is plugged into what),
`SHARES.md` (what data is on it).

> **This log has a predecessor.** Tower's first NixOS identity was `liskov`, a
> minimal hypervisor that would have run the existing Unraid install as a KVM
> guest with the SATA controllers passed through. It was built, validated,
> and — on the strength of `DESIGN.md`, which was commissioned to attack it —
> retired on 2026-08-07 without ever being installed. Its decision log is in git
> history at `hosts/liskov/DECISIONS.md`. The entries below are the ones that
> outlived it, plus the ones the retirement itself forced.
>
> Dates are UTC.

---

## 1. The name

**`galactica`, replacing `liskov`** — *alt:* keep `liskov`; `perlman`; `tower`;
`tower-hv`; `atlas`; `creasy`.

*Why a new name at all:* the machine's job changed. `liskov` was chosen for the
substitution principle, which was the hypervisor's literal contract — the guest
had to be indistinguishable from bare-metal Tower, down to the MAC address, or
memory-alpha's NFS mounts and the DHCP reservation would break. Under bare metal
there is no guest and no substitution; the name would be a fossil pointing at an
argument that no longer applies.

*Why `galactica`:* an old ship, not fast or flashy, built to be resilient and
take punishment before returning the favour. That is the design in `DESIGN.md` —
a 2011 Xeon carrying dual parity over disks that cannot be quickly replaced,
chosen for the ability to degrade rather than to be quick. `perlman` was the
other candidate and a good one; the tiebreaker was thematic fit rather than
merit.

⚠ **The name has been used before in this fleet.** A previous machine called
galactica predated pegasus and has been gone for roughly five years. The
practical consequence is `known_hosts`: any client that still holds an entry for
the old host will refuse to connect and print a host-key-mismatch warning that
reads as a man-in-the-middle attack. It is not one. Clear the stale entry rather
than disabling the check:

```sh
ssh-keygen -R galactica.internal
ssh-keygen -R <ip>
```

*Note:* `galactica` was among the alternatives when `liskov` was originally named
and lost. It won on the second pass because the job description changed.

## 2. `tower.internal` continuity is now a DNS problem, not a naming constraint

**The host takes the name `galactica`; `tower.internal` follows it via an AdGuard
rewrite** — *alt:* name the host `tower`; rely on the router deriving DNS from
the DHCP hostname option.

*Why:* under the VFIO plan `tower.internal` had to keep resolving to the *guest*,
because the guest was Unraid and the fallback was booting bare metal. That
constraint is gone — bare metal, the machine simply *is* `tower.internal`, and
the fleet's dependents (memory-alpha's two NFS mounts, its NUT client,
serenity's mounts) care about the name and the address, not the hostname the DHCP
lease advertises.

hopper already runs AdGuard Home (`modules/nixos/dns.nix`), so a rewrite
`tower.internal → <IP>` is one line and **decouples the fleet name from the
service name permanently.** Do that. Do not name the host `tower` — that would
put the fleet identity and the service identity back in the same string, which is
exactly the coupling that made the previous plan awkward.

## 3. Why there is no config here yet

**Documentation-only until the storage layout is settled** — *alt:* scaffold a
`configuration.nix` now and fill in the disks later.

*Why:* almost everything in a `configuration.nix` for this host is downstream of
decisions that have not been made — which disks are data, which are parity,
whether a 12 TB is held back as a cold spare, how the photo tier is built, and
what `DESIGN.md` §5's data classification concludes. Scaffolding now would mean
writing a file whose every interesting line is a placeholder, and placeholders in
a `.nix` file are worse than absence: they evaluate, they look like decisions,
and they get copied.

The fleet boilerplate (users, SSH, nix settings, timezone, home-manager wiring)
is a twenty-minute derivation from `hosts/memory-alpha/configuration.nix` when
the time comes. It is not worth pre-writing.

**What this costs:** the flake has no `nixosConfigurations.galactica`, so CI
cannot evaluate anything here, and the `.sops.yaml` staging stanza is absent too
(see 4).

## 4. sops staging is deferred with the config

**No `&galactica` key and no `secrets/galactica.yaml` creation rule until there
is a host config to gate on it** — *alt:* add the placeholder stanza now, as
hopper and hamilton have.

*Why:* the placeholder pattern exists so a host's closure evaluates before the
machine has booted and produced a real age key. With no closure, there is nothing
to evaluate and nothing to gate — the stanza would be inert.

**When it lands it should look like hopper's and hamilton's, with one difference
worth recording now:** those two are encrypted to `*admin` plus `*memory-alpha`,
because memory-alpha is their aarch64 build host and validates secrets at
image-build time. galactica is x86_64 and builds its own closure, so **it needs
`*admin` only** until first boot, then `*galactica` is added and
`sops updatekeys` re-run.

## 5. Serial console stays a module option

**`modules/nixos/serial-console.nix` is kept despite having no importer** —
*alt:* delete it with the rest of the liskov config and hardcode
`boot.kernelParams` when galactica's config lands.

*Why:* the option exists because the console device is a property of the
*machine*, not of the config, and the machine has not changed — the same BMC
still puts Serial-over-LAN on COM2 (`ttyS1`) while anything QEMU-hosted has only
`ttyS0`. The hardcoded form cost a real debugging session: `boot.kernelParams` is
a list, a single entry cannot be removed by an overriding module, and the VM
variant inherited `ttyS1`, registered a console on a UART that did not exist, and
bound the login prompt to a device that never appeared. It booted correctly in
five seconds and offered no way in.

An orphaned module is cheap. Re-learning that is not.

## 6. Documentation split three ways

**`PLATFORM.md` / `HARDWARE-MAP.md` / `DESIGN.md`, rather than one runbook** —
*alt:* keep the single `DEPLOY.md` and edit it in place.

*Why:* the old `DEPLOY.md` mixed three things with completely different
lifetimes — a procedure that is rewritten whenever the plan changes, hardware
facts that are true regardless of the plan, and the reasoning behind the plan
itself. Retiring the hypervisor would have meant deleting or rewriting a document
that also happened to hold the only record of the ASM1166 flash-tool segfault,
the BMC's argument-parsing traps, and the measured port speeds. That is the
failure mode the split prevents.

`hosts/pegasus/home.nix` and `hosts/serenity/home.nix` both cite the IPMI
invocations from their `freeipmi` package comments; they now point at
`PLATFORM.md §2`, which is a reference section rather than a step in a procedure.

**No `DEPLOY.md` exists right now.** It gets written when there is something to
deploy, and it should be short — the durable material has already been extracted.

---

## Carried forward from the VFIO plan

Constraints and findings that were established under the previous design and
remain true under this one.

- **The arr stack and download clients share one `/data` root.** Imports are
  hardlinks and moves are atomic; hardlinks cannot cross a filesystem boundary,
  so splitting them turns every import into a full copy. Under mergerfs this
  becomes a *policy* constraint rather than a topology one — see `DESIGN.md`
  §4.6 on `EXDEV` and non-path-preserving create policies — but the discipline is
  the same.
- **A dedicated torrent drive outside the parity set, accepting the copy.** A
  write to a parity-protected disk costs four operations across two spindles
  (read old data, read old parity, compute, write both), and torrent downloads
  are precisely the write pattern you least want paying that. Parity would also
  be protecting, by definition, the most re-downloadable data on the machine, and
  seeding is constant random reads that then never contend with a sync or a
  scrub. **The copy is paid once per import; the parity tax would be paid on
  every write, forever.** Size it against *seeding retention* rather than library
  size, since seeded content exists twice.
- **No Ceph, no Incus clustering, no LSI HBA.** Considered and ruled out before
  either design; not revisited.
- **Bind PCI devices by vendor:device ID, not bus address** — addresses have been
  observed to shift across reboots on this board. Now only relevant if libvirt
  ever comes back, but the observation stands.
- **FreeIPMI on both serenity and pegasus**, so neither one being down blocks
  recovering the other. The BMC is how a LUKS prompt is reached and how a wedged
  box is power-cycled.

## Reversed by the move to bare metal

Decisions that were correct under the VFIO plan and are not correct now. Recorded
because each was reasoned about at length and a future session should not have to
re-derive why it stopped applying.

- **NUT server duty moving to memory-alpha.** The whole argument was that
  virtualizing Tower puts the UPS USB on the host, leaving the host — which
  physically holds every disk — unable to see the UPS. Bare metal dissolves it:
  the UPS plugs into the NixOS host, `modules/nixos/nut.nix` makes it the server,
  and memory-alpha stays a client. **No cable move is needed.** See `DESIGN.md`
  §4.7.
- **The array belongs on the ASM1166.** Under passthrough it had to be — onboard
  SATA was never passed through, so an array left there would have been invisible
  to the guest. Under bare metal the reasoning inverts: the onboard SATA 2.0
  ports give each spinner a *dedicated* ~275 MB/s, which exceeds the 12 TB
  drives' ~250 MB/s peak, where the ASM1166 at Gen2 gives all six ports a
  *shared* ~1.0 GB/s. **The array belongs on onboard.** `PLATFORM.md §8`.
- **No auto-unlock for the encrypted disks.** Under Unraid the array was unlocked
  inside the guest by Unraid's own machinery, so nothing host-side could remove
  the manual step. Under bare metal, sops-nix keyfiles decrypt at boot under the
  host SSH key and `/etc/crypttab` opens the pools. ⚠ That is a **posture
  change**, not a free win: encryption then protects a powered-off stolen
  chassis, not a running one. It is the same trade the rest of the fleet has
  already made.
- **`q35` + OVMF, guest sizing, vCPU pinning, `libvirtd.onShutdown`,
  `memballoon`, the `br0` bridge.** All properties of a guest that no longer
  exists.

## Still open

- **The data classification.** `DESIGN.md` §5 assumes a split between
  irreplaceable data (photos — real-time redundancy, checksummed) and
  re-acquirable data (media — snapshot parity, 24 h lag acceptable). The owner
  has flagged that more categories exist and that classifying them properly will
  materially change the layout. **This is the blocking item.** Nothing else
  should be decided ahead of it.

  **Scaffolded 2026-08-07:** `SHARES.md` now carries all 34 Unraid shares, where
  each physically lives, and a five-tier starting proposal. Fourteen shares sit
  in a `⟨?⟩` row whose contents cannot be inferred from configuration — that row
  is the remaining work, and most of it is one question per share: *if this
  vanished, could I get it back, and at what cost?*
- ~~**Which 12 TB is which.**~~ **Closed 2026-08-07** from Unraid's Main tab:
  parity `h-X4WE`, parity-2 `h-HJDH`, disk-1 `h-T97E`, disk-2 `h-NS3Y`. The same
  reading confirmed the encryption inferences in `HARDWARE-MAP.md` §2 exactly, put
  the array at **17.1 TB used of 24 TB**, and closed the `/mnt/services` btrfs
  question. Caddy labels for the four 12 TB disks are now printable — roles stay
  off them by design (`DISK-LABELLING.md` §3); the map is what carries the role.
- **Whether to hold a 12 TB back as a cold spare.** There is no budget for a
  fifth and the drive market makes rapid replacement unlikely. Analysed in
  `DESIGN.md` §5.5; the short version is that shelving one costs 12 TB of usable
  capacity to buy protection dual parity provides more cheaply.
- **The Gen3 retest** (`PLATFORM.md §6e`). One reboot, benign failure mode,
  and it decides the NVMe root's ceiling. Should happen before any disk placement
  is finalised.
- **The ASM1064's PCIe x1 link.** Four SATA ports on one lane is ~500 MB/s
  shared at Gen2, which a single SATA SSD nearly saturates. Measure it
  (`PLATFORM.md §8`) before it gets mistaken for something else.
- **Tower's other cages**, beyond the built-in four-slot hotswap one, and the
  port-to-bay mapping for it. `HARDWARE-MAP.md` §3 carries placeholders. The
  *controller* half is now measured (§4) — what remains is purely which physical
  bay each disk occupies, which sysfs cannot answer.
- ~~**The five drawer spinners' serials.**~~ **Closed 2026-08-07** — read from
  label photographs. There are **twelve**, not five (~23.5 TB), all identified in
  `docs/DISK-DRAWER.md`. Two findings from that pass are now open in its place:
  - **Only one 4 TB disk is CMR.** The other two are WD Red EFAX, which are
    DM-SMR, so the photo tier cannot be an all-CMR pair without buying a disk.
    Options tabulated in `DISK-DRAWER.md`; **no SnapRAID parity on an EFAX**
    under any of them.
  - **The Samsung 2 TB has the HD204UI firmware defect** where a SMART command
    during a write can corrupt data. Check its firmware revision before use.
    Everything in this fleet polls SMART constantly.

  Two label characters still need confirming at attach time: the `0`/`O` in
  `h-6D0X` (inside the four-char suffix, so it affects the identifier) and
  whether `h25-P4TH` is 40 GB or 60 GB.
- **Staging capacity.** Three 4 TB disks are available for the migration, which
  is not enough for everything at once; the plan assumes *arr* media is winnowed
  to fit. `DESIGN.md` §6.
