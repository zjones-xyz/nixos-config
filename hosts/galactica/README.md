# galactica — Tower's NixOS identity

**Supermicro X9SCM-F, Xeon E3-1230 v2, 32 GB.** Ran Unraid 7.3.2 on bare
metal for years; now bare-metal NixOS. Root is LUKS + btrfs on the NVMe
(fleet-standard); the media array is `tank` — ZFS RAIDZ1 across the four
12 TB spinners plus a 3-way-mirror SSD special vdev, LUKS underneath —
**built live and cold-boot-verified 2026-09-01**, with the Unraid data copied
back from the `sidepool` staging pool on 2026-09-02. See `MANUAL-STEPS.md`
for what's still outstanding (NUT/UPS, Beszel agent, NFS re-export cutover,
the nixarr media import from `tank/media_staging`).

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

## Doc status

The storage sections of `DESIGN.md`/`DECISIONS.md` describe the retired
SnapRAID + mergerfs plan and were **reconciled 2026-09-02 (PR #87)**: each
carries a superseded-banner pointing at what was actually built (the ZFS
`tank` array above), with the original prose kept as provenance. The
platform-level verdicts (why bare metal, why not VFIO) still stand. Read the
banners before trusting any storage detail in those two files;
`MANUAL-STEPS.md` §9 is the build record.
