# galactica — Tower's NixOS identity

**Supermicro X9SCM-F, Xeon E3-1230 v2, 32 GB.** Was running Unraid 7.3.2 on
bare metal for years; migrating to bare-metal NixOS with a native ZFS RAIDZ1
array (LUKS underneath, not SnapRAID + mergerfs — see the "Blocking item"
section below, this replaced the original plan outside this repo).

`configuration.nix`, `disko.nix`, and `home.nix` now exist (root: LUKS +
btrfs, matching the fleet), and `nixosConfigurations.galactica` is wired into
`flake.nix` against a real, disko-reconciled `hardware-configuration.nix`. See
`MANUAL-STEPS.md` for what's still outstanding (the array rebuild, an
unconfirmed DNS fix, NUT/UPS, Beszel agent, NFS re-export cutover).

## The five documents

| File | Answers | Read it when |
|---|---|---|
| **`DESIGN.md`** | *What is being built and why.* The case for leaving Unraid, the SnapRAID/mergerfs stack, failure modes, storage layout, migration plan. | Deciding anything. This is the plan of record. |
| **`PLATFORM.md`** | *What the machine does.* BIOS quirks, BMC/IPMI access, controller firmware, bus speeds, and how to tell which limit you are hitting. | Standing in front of the machine, or before believing a benchmark. |
| **`HARDWARE-MAP.md`** | *What is plugged into what.* Disks, cages, bays, controllers, ports, label strings. | Pulling a drive, or printing labels. |
| **`SHARES.md`** | *What data is actually on it.* Unraid's 34 shares, where each physically lives, and the classification the layout waits on. | Deciding tiers, or planning the migration. |
| **`DECISIONS.md`** | *Why it is this way.* Decision → alternatives → rationale, what the previous design got right, and **`## Still open`**. | Before changing something that looks arbitrary. |

Fleet-wide: `docs/DISK-LABELLING.md` (naming and labelling convention),
`docs/DISK-DRAWER.md` (unassigned disks), `docs/BACKUP.md` (who owes what an
offsite copy, and Tower's lack of one).

## Naming

`galactica` — an old ship, not fast or flashy, built to be resilient and take
punishment before returning the favour. It replaces `liskov`, the hypervisor
identity this machine carried while the plan was to virtualize Unraid rather than
leave it; that design was retired 2026-08-07 and lives in git history.

⚠ A previous fleet machine used this name and has been gone for about five years.
Stale `known_hosts` entries will present as a host-key-mismatch warning that
reads like a MITM attack. `DECISIONS.md` §1.

`tower.internal` continues to resolve to this machine — via an AdGuard rewrite on
hopper rather than via the hostname, so the fleet name and the service name stay
decoupled. `DECISIONS.md` §2.

## Blocking item

⚠ **The storage design below (`DESIGN.md`, `DECISIONS.md`) has been
superseded outside this repo, and this section is stale.** As of 2026-08-31
the live plan is native ZFS RAIDZ1 across the four 12 TB drives (LUKS
underneath, not ZFS-native encryption — matches this host's existing
LUKS-everywhere convention), staged via a temporary btrfs pool
(`sidepool`) built on an LSI HBA, not SnapRAID + mergerfs. Reconciling
`DESIGN.md`/`DECISIONS.md` with that decision is a real rewrite that hasn't
happened yet — treat the storage-layout discussion below as historical
context for *why bare metal* and *why not SnapRAID as originally scoped*,
not as the current plan.
