# Fleet backup

What is backed up, by whom, to where — and the parts that are not yet.

This is fleet-scoped because the governing question is *which machine owes the
obligation*, which no single host's docs can answer. Per-host data
classification lives with the host (`hosts/galactica/SHARES.md` for Tower).

Dates are UTC.

---

## 1. The principle

> **An offsite obligation belongs to the machine that owns the data, not to
> whatever happens to hold a copy of it.**

Established while classifying Tower's `serenity_time_machine` share, 2026-08-07.
Three reasons it holds:

- **Backing up a backup is a bad path.** A copy-of-a-copy is one more hop from
  the source, often in an opaque intermediate format, and restoring means
  recovering the intermediate first.
- **The source of truth should own its own durability.** Only the owning machine
  knows what changed and when.
- **It keeps the expensive tier honest.** Offsite is the recurring cost;
  absorbing another machine's obligation is how that cost quietly grows.

⚠ The corollary is that holding someone's backup does **not** discharge your own.
Tower holds Serenity's Time Machine copy and is itself unbacked.

## 2. Current state, honestly

| Host | Local redundancy | Offsite | Declarative? |
|---|---|---|---|
| **serenity** (Mac) | — | **Three paths:** iDrive subscription; Time Machine to a drive kept at the makerspace; Time Machine to a drive kept at family. | No — all outside Nix |
| **galactica / Tower** | Dual parity (Unraid today, SnapRAID planned) + btrfs on pools | ⚠ **None** | n/a |
| **pegasus** | btrbk local snapshots (`modules/nixos/btrfs-snapshots.nix`) | ⚠ **None** | Snapshots yes |
| memory-alpha, hopper, hamilton | ⟨unsurveyed⟩ | ⟨unsurveyed⟩ | ⟨unsurveyed⟩ |

**Nothing in this fleet runs declarative backup software.** A grep for `restic`,
`borgbackup`, `rclone` and `kopia` across every `.nix` returns nothing. The only
adjacent thing is btrbk on pegasus, whose own module comment is emphatic that it
is not a backup: every snapshot sits on the same filesystem, same disk, inside
the same LUKS container as the data.

**Serenity's arrangement is good and needs no help.** It comfortably exceeds
3-2-1, and the two rotated drives are *air-gapped*, which no cloud target is.
Note the logistics: **the drives live at those sites permanently and the laptop
travels to them.** Nothing has to be carried, which is exactly why the habit
survives.

⚠ **Parity is not a backup.** Tower's dual parity covers a disk dying. It does
not cover deletion, ransomware, filesystem corruption written through to parity,
fire, or theft.

## 3. Tower's scope

From `hosts/galactica/SHARES.md` §5, the tiers that need offsite:

| Tier | Shares | Notes |
|---|---|---|
| **Critical** | `documents` | Small, changes often, **needs versioning and a tested restore** |
| **Precious** | `immich_photos`, `immich_photos_archived` | The bulk. Append-mostly. |

Plus whichever `appdata` subtrees inherit those tiers — a service's `appdata`
takes the highest tier of any data share it indexes, so Immich's database is
Precious-adjacent regardless of what the rest of `appdata` is.

**Photos are scattered-but-extant.** Originals have generally not been deleted
from their original sources, so total loss is not permanent loss — it is weeks of
archaeology across phones, old laptops, SD cards and cloud accounts, plus silent
partial loss wherever a source has since died. **The irreplaceable artifact is the
consolidation, not the bytes.** That keeps the tier Precious for a softer reason
than "only copy", and it means an imperfect backup here is worth a great deal.

⚠ **Sizing gates the mechanism, and does so qualitatively.** Run:

```sh
du -sh /mnt/user/immich_photos /mnt/user/immich_photos_archived /mnt/user/documents
```

- **Photos under ~1 TB** → put the whole Precious tier in object storage for a
  few dollars a month and skip physical rotation entirely. No new habit.
- **Photos well over that** → rotation starts earning its keep, and the air-gap
  becomes a feature rather than a consolation.

## 4. Tool: restic, on one constraint

**The owner's objection to iDrive is specific**: the subscription cannot cover
Tower. Not vendor sprawl, not tooling. iDrive's own **e2** product is
S3-compatible object storage and would work — but it is a separate product from
the iDrive Personal plan Serenity uses, so "one subscription covers everything"
is not on offer either way.

That makes the decision mechanical:

> **iDrive e2 is S3. Borg does not speak object storage** — it wants a local
> filesystem or SSH to a host running `borg serve`.

- **Keep e2 on the table → restic.** It talks S3, local disk, SFTP and
  rclone-anything, so one tool covers the cloud target, the rotated USB drive,
  and any provider switched to later.
- **Prefer borg → choose an SSH-based host instead**: rsync.net, BorgBase, or a
  Hetzner Storage Box. All fine; none of them iDrive.

**Recommendation: restic.** Not because borg is worse — its dedup and compression
are excellent, and its server-side append-only mode is a genuine ransomware
defence restic can only approximate with object lock. The deciding argument is
that one tool across every target means **one restore procedure to test**, and
restores are where backup plans die. Two procedures doubles the surface you are
pretending to have verified.

NixOS has `services.restic.backups.<name>`; nothing in this fleet uses it yet.

### Both tools fix the thing that annoys about iDrive

The owner's other iDrive friction is key handling. Consumer backup products
typically bind the data to the key such that **rotating it means re-uploading
everything**, and degrade their web restore when private-key encryption is on.

restic and borg both avoid this by construction: the repository is encrypted with
a master key, and your passphrase merely *wraps* that master key. So
`restic key add` / `restic key remove`, or `borg key change-passphrase`, rotate
credentials in milliseconds without touching a byte of stored data.

## 5. ⚠ The key custody problem — design this before trusting anything

Self-managed encryption removes the vendor's ability to lose your key. It also
removes their ability to help you recover it. **The backup key becomes Critical
data that cannot be stored in the backup**, and the fleet's current trust chain
is circular:

```
restic repo  ←  restic passphrase  ←  sops  ←  admin age key  ←  ⟨a machine⟩
```

Follow it through the scenario the offsite copy exists for. A fire takes Tower.
The host age key dies with it. `secrets/galactica.yaml` is still decryptable by
the `*admin` key — which lives on Serenity, per this repo's own "edit from the
Mac" convention. **If the same event takes both, the offsite backup is
undecryptable ciphertext**, perfectly preserved and permanently useless.

Serenity being a laptop that travels helps, and is close to luck rather than
design.

**What closes it:** at least one copy of the credential that depends on no
machine in the fleet. Options, not mutually exclusive —

- **Paper**, in a fireproof box or a safe deposit box. Unglamorous, works,
  survives EMPs and format rot.
- **With the rotated drives**, sealed, at the makerspace or family site. The
  drives already go there and the sites are already trusted.
- **A hardware token.** `modules/nixos/yubikey.nix` exists, so there may already
  be one in the fleet — ⟨confirm what it is used for⟩.

⚠ **A restore test must start from zero.** Restoring on a machine that already
holds the keys tests the tool, not the plan. The Critical tier's "tested restore"
requirement means: from a live USB, with nothing but what is in the fireproof
box, can you get `documents` back? Anything less is rehearsing the easy half.

## 6. Open

- **Size the Critical and Precious tiers** (§3). Gates the mechanism.
- **Choose the provider** once sized — e2, B2, rsync.net, Hetzner all viable;
  restic makes the choice reversible.
- **Verify object lock / bucket versioning** on whichever provider, if restic's
  append-only approximation is wanted.
- **Design key custody** (§5) *before* the first backup runs, not after.
- **Decide on physical rotation for Tower.** ⚠ Unlike Serenity's, this habit
  requires the *drive* to travel, which is materially harder to sustain than
  "plug in while you're there". A USB3 dock costs nothing from Tower's SATA port
  budget (full at 12/12) since USB3 comes off the ASM1042 card.
- **Survey memory-alpha, hopper and hamilton.** They are blank in §2 because
  nobody has looked, not because they are known to have nothing.
