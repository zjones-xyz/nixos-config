# galactica — Tower's NixOS identity

**Supermicro X9SCM-F, Xeon E3-1230 v2, 32 GB.** Currently running Unraid 7.3.2
on bare metal, as it has for years. The plan is to replace that with bare-metal
NixOS running SnapRAID + mergerfs.

⚠ **There is no `configuration.nix` in this directory, and that is deliberate.**
This host is documented before it is configured, because almost every line of its
eventual config is downstream of a storage layout that has not been decided yet.
See `DECISIONS.md` decision 3. Consequently there is no
`nixosConfigurations.galactica` in the flake and no `secrets/galactica.yaml`
staging in `.sops.yaml` — both land together with the config.

## The five documents

| File | Answers | Read it when |
|---|---|---|
| **`DESIGN.md`** | *What is being built and why.* The case for leaving Unraid, the SnapRAID/mergerfs stack, failure modes, storage layout, migration plan. | Deciding anything. This is the plan of record. |
| **`PLATFORM.md`** | *What the machine does.* BIOS quirks, BMC/IPMI access, controller firmware, bus speeds, and how to tell which limit you are hitting. | Standing in front of the machine, or before believing a benchmark. |
| **`HARDWARE-MAP.md`** | *What is plugged into what.* Disks, cages, bays, controllers, ports, label strings. | Pulling a drive, or printing labels. |
| **`SHARES.md`** | *What data is actually on it.* Unraid's 34 shares, where each physically lives, and the classification the layout waits on. | Deciding tiers, or planning the migration. |
| **`DECISIONS.md`** | *Why it is this way.* Decision → alternatives → rationale, what the previous design got right, and **`## Still open`**. | Before changing something that looks arbitrary. |

Fleet-wide: `docs/DISK-LABELLING.md` (naming and labelling convention),
`docs/DISK-DRAWER.md` (unassigned disks).

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

**The data classification** (`SHARES.md` §5). The layout assumes a two-way split
between irreplaceable data and re-acquirable data; the owner has flagged that
more categories exist and that classifying them properly will materially change
the result. `SHARES.md` now carries the 34 shares and a starting proposal to
argue with. Nothing else should be decided ahead of it.
