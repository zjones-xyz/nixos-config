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

### ✅ Budget: 500 GB of cloud storage — physical rotation is off the table

**Owner, 2026-08-07.** That settles the mechanism question that sizing was gating,
and it settles it toward the simpler answer: **cloud only, no drive swap, no new
habit.**

Roughly $3/month at commodity object-storage rates (~$6/TB/month); iDrive e2 and
Backblaze B2 are both in that neighbourhood, e2 typically cheaper on an annual
commitment. Against that, a rotation habit costs a dock, two drives, and a ritual
that has to survive contact with a busy month — see §6 on why Tower's version of
that habit is harder than Serenity's.

⚠ **Still measure the tiers**, because the budget is a ceiling, not a fit:

```sh
du -sh /mnt/user/immich_photos /mnt/user/immich_photos_archived /mnt/user/documents
```

**Expect the stored size to be close to the source size.** restic dedups and
compresses, but photos are already-compressed JPEG/HEIC and will store at
roughly 1:1. `documents` may compress well, and it is small either way. So plan
as though 500 GB of budget buys about 500 GB of photos.

If the Precious tier overflows the budget, the options in preference order are:
raise the budget (it is single-digit dollars per 500 GB), cloud the newer
material and leave the deep archive to the scattered-but-extant originals (§3),
or reintroduce rotation for the overflow only.

### ⚠ Cloud-only loses the air-gap — buy most of it back with a restricted key

Serenity's rotated drives are air-gapped by construction: a compromised machine
cannot reach a disk sitting in another building. Cloud-only gives that up, and
the specific scenario is that something with root on Tower deletes the backups
before anyone notices.

**Do not give Tower a credential that can delete.** Both B2 and e2 support scoped
keys and object lock / bucket versioning:

- **Tower's key writes and lists, and cannot delete or overwrite.** restic is
  happy in this mode for `backup`; it only needs delete rights for `prune` and
  `forget`.
- **Run `prune` from elsewhere, rarely** — the admin machine, with a separate
  privileged key that never lives on Tower.
- **Enable object lock or versioning** on the bucket so that even a mistaken
  privileged delete is recoverable for a retention window.

That recovers most of the air-gap benefit for none of the logistics, and it is
the single highest-value configuration choice in this document. ⚠ Verify the
specific provider's key-scoping semantics before relying on it — "supports object
lock" on a pricing page is not the same as "restic works correctly against a
no-delete key on this provider".

## 3b. Monitoring — the fleet already has both halves

**Requirement, owner 2026-08-07: be loud when the budget is approached, and loud
when something has not checked in for a while.**

Both pieces already run, and — importantly — **they run on hopper, not Tower**:

| Piece | Where | Role here |
|---|---|---|
| **ntfy** (`modules/nixos/ntfy.nix`) | hopper, `ntfy.hopper.internal` | Alert sink. Existing pattern in `nut.nix`: `curl` to a topic with priority/tags headers |
| **Uptime Kuma** (`modules/nixos/uptime-kuma.nix`) | hopper, `kuma.hopper.internal` | **Push monitors** — a dead-man's switch primitive |

⚠ **Keep the monitors off Tower.** A watcher hosted on the machine it watches
goes down with it and reports nothing, which is the failure mode this whole
section exists to prevent. hopper is already the right home; do not "simplify"
by moving them later.

### The three signals

**1. Heartbeat — did the backup run at all?**

An Uptime Kuma **push monitor**: Tower `curl`s the push URL *only on success*, and
Kuma raises an alert if it does not hear within the window.

**This is the one that matters most, because it fails closed.** Machine off,
service crashed, timer never fired, a rebuild quietly broke the unit, network
down — all of them produce silence, and silence is the alarm. Contrast with a
systemd `OnFailure=` handler, which requires the failing thing to be alive and
healthy enough to report its own failure. Use both, but trust the heartbeat.

⚠ Set the interval with slack — for a nightly job, something like 26–30 hours
rather than exactly 24, or ordinary jitter and a slow run will cry wolf. A monitor
that false-alarms is a monitor that gets muted.

**2. Budget — is the repo approaching 500 GB?**

After each run, `restic stats --mode raw-data`, compared against thresholds and
posted to ntfy with escalating priority — 80% informational, 90% high, 100%
urgent. Follow the `nut.nix` curl pattern rather than inventing a second one.

**3. ⚠ Did the backup contain anything? — the failure that defeats both above**

If a source path exists but its filesystem is not mounted, restic will happily
snapshot an empty directory, **exit 0, ping the heartbeat, and not grow the
repo**. Heartbeat green, budget quiet, backup worthless. On a host whose data
lives behind mergerfs and LUKS this is a realistic Tuesday, not an exotic edge
case.

Guards, best first:

- **`RequiresMountsFor=`** on the backup unit. systemd then refuses to start the
  job at all if the mount is absent. Declarative, fails closed, no scripting.
- **A canary file** per source tree, verified present in the latest snapshot.
- **A file-count delta check** against the previous snapshot, alarming on a large
  drop.

### The two mechanisms cover each other

Worth noticing, because it is the property that makes this robust rather than
merely present:

- Budget alerts are **pushed from Tower**, so they fail silently if Tower cannot
  reach hopper.
- The heartbeat is **absence noticed by hopper**, so it fires *precisely* when
  Tower cannot reach hopper.

Each one's blind spot is the other's trigger condition.

### Also worth a timer: the restore-test nag

The Critical tier requires a *tested* restore (§5), and that is the discipline
that silently never happens. A quarterly ntfy post saying "test a restore" costs
one systemd timer and is the difference between a plan and a belief.

## 4. Tool: restic, borg, kopia

**Versions in this flake's pinned nixpkgs**, evaluated 2026-08-07 rather than
recalled: `restic` **0.19.1**, `borgbackup` **1.4.5**, `kopia` **0.23.1**,
`rclone` **1.74.4**.

### The two facts that decide it

Everything else is a feature comparison; these two are structural.

**1. Borg does not speak object storage.** It wants a local filesystem or SSH to
a host running `borg serve`. There is no S3 backend and there will not be one —
it needs POSIX semantics and locking that object storage does not provide. So
borg is not "restic with different tradeoffs" here; **it is a different storage
decision**, and picking it means choosing rsync.net, BorgBase or a Hetzner
Storage Box instead of iDrive e2.

**2. Kopia has no NixOS module.** Checked directly against the pinned tree:
`nixos/modules/services/backup/` ships `restic.nix`, `restic-rest-server.nix`,
`borgbackup.nix` and `borgmatic.nix`, and `services.kopia` does not exist
anywhere in `nixos/modules`. Kopia is packaged, not integrated.

That matters more here than it would elsewhere. `DESIGN.md` §3.2's argument for
this whole migration is that **the machine becomes reviewable** — configuration
in the flake, under CI, in a PR. Hand-rolled systemd units wrapping an
imperatively-configured kopia repository is precisely the shape being migrated
*away from*. Kopia is a good program; it is the wrong fit for this fleet's
premise.

### Where each genuinely wins

| | restic 0.19.1 | borg 1.4.5 | kopia 0.23.1 |
|---|---|---|---|
| **Object storage (e2/B2)** | ✅ native | ❌ **none** | ✅ native |
| **Other backends** | local, SFTP, REST, Azure, GCS, Swift, rclone | local, SSH | SFTP, WebDAV, rclone, local |
| **NixOS module** | ✅ `services.restic.backups.*` | ✅ `services.borgbackup.jobs.*` | ❌ **none** |
| **Server-side append-only** | via `rest-server --append-only`; on S3 relies on object lock | ✅ `borg serve --append-only` — enforced | repo-server ACLs; on S3 relies on object lock |
| **Multiple hosts → one repo** | ✅ supported | ⚠ footgun; prefer a repo per host | ✅ designed for it |
| **Key custody** | **one secret** (the repo password) | repokey = one secret; keyfile = key **and** passphrase | one secret |
| **GUI** | — | — | ✅ KopiaUI |
| **Maturity / community** | large, active | oldest and most battle-tested; borg 2 long in beta | newest, thinnest |

**Borg's real advantage is `borg serve --append-only`** — enforced by the storage
server, not by a cloud IAM policy you have to trust yourself to have written
correctly. That is a stronger ransomware guarantee than §3's restricted-key
approximation. If the append-only property mattered more than the provider
choice, borg plus rsync.net would be the pick.

**Kopia's real advantage is ergonomics** — KopiaUI, automatic maintenance,
error-correction options. Tower is headless and the fleet wants declarative
config, so neither lands.

⚠ **Kopia's automatic maintenance actively fights §3's design.** It runs quick and
full maintenance on its own schedule, which means the backup credential needs
delete rights routinely. restic separates cleanly: `backup` needs no delete
rights at all, and `forget`/`prune` run rarely and from elsewhere with a
privileged key. That separation is what makes the no-delete credential possible,
and it is not incidental to the choice.

### ⚠ Proton Drive — evaluated 2026-08-07, not recommended

**Short answer: possible with restic via rclone, impossible with borg, and a
security regression either way.**

Checked against the rclone shipped in this flake's pinned nixpkgs (**1.74.4**),
reading its own backend documentation rather than recalling:

- ✅ **A `protondrive` backend exists.** So `restic -r rclone:proton:path` is a
  real configuration, not a hypothetical.
- ❌ **Borg cannot use it at all.** Borg needs a local filesystem or SSH, so the
  only route is `rclone mount` and pointing borg at the FUSE mount. Borg does
  heavy random access against its segment files and expects POSIX locking
  semantics; running it over a FUSE mount of a reverse-engineered cloud API is a
  repository-corruption machine. **Do not.**

**The disqualifying problem is credentials, not performance.** rclone's
protondrive backend authenticates with `--protondrive-username` and
`--protondrive-password` — *your Proton account password* — plus the 2FA code or
`--protondrive-otp-secret-key`. Session tokens (`client_access_token`,
`client_refresh_token`, `client_salted_key_pass`) can be supplied afterwards, but
the bootstrap needs full account credentials and the tokens grant Drive access.

There is **no scoped application key, no no-delete credential, and no object
lock.** Compare §3, where the single highest-value configuration choice is giving
Tower a key that can write but not delete. Proton offers no such thing — and the
blast radius of a compromised Tower is not "the backup bucket" but *the Proton
account*: mail, calendar, VPN, everything. That is strictly worse than the status
quo of having no offsite copy at all in one specific sense — it creates a new
loss scenario that does not currently exist.

Two further caveats from rclone's own docs, both directly hostile to how restic
writes:

- **Interrupted uploads leave a draft**, and the next upload to that path
  "will be reported as a conflict". Default behaviour is to fail with *"a draft
  exist"*. restic writes many pack files per run, so one network blip poisons a
  path until cleared. The fix is `replace_existing_draft=true`, whose docs say
  that with concurrent clients **"the behavior is currently unknown"**.
- **Metadata caching assumes rclone is the only client.** The docs are explicit
  that Proton's event system "is yet to be implemented, so updates from other
  clients won't be reflected in the cache" — so the Proton desktop and mobile
  apps syncing the same account can desynchronise it.

**And the value proposition cancels out.** Proton Drive's selling point is
end-to-end encryption. restic already encrypts everything before it leaves the
host, so the payload is ciphertext either way — you would pay a performance and
reliability tax for a privacy property you already have, delivered over a less
tested path.

⚠ **Not as the only offsite copy of the Precious tier.** Against roughly $3/month
for B2 or iDrive e2 — both first-class S3 targets, and note rclone lists **IDrive**
by name among its S3 providers — Proton buys nothing this design wants and costs
the credential scoping the design is built around.

**If the storage is already paid for and going unused**, the defensible shape is
a *secondary* copy of the small Critical tier only, run from a machine that is
not Tower, so the Proton credential never lives on the fileserver. That preserves
provider diversity for the data that matters most without handing a fileserver
the keys to an entire identity. Even then, a second S3 vendor is simpler.

### Key custody favours restic, mildly

§5 requires a copy of the credential that survives losing every machine. restic's
model is **one secret** — the repository password, which unwraps the master key —
so the fireproof-box copy is a passphrase written on paper. Borg's *repokey* mode
is equivalent, but its *keyfile* mode splits custody in two: the key lives in
`~/.config/borg/keys` and the passphrase protects it, so losing the machine loses
the key even if you remember the passphrase. Borg ships `borg key export --paper`
precisely because that failure is real — a good solution to a problem restic does
not have.

All three rotate credentials cheaply, which is the property that fixes the iDrive
annoyance (below).

### Recommendation: restic

Ranked, decisive first:

1. **It talks S3**, so iDrive e2 stays a live option and the provider stays
   swappable later. Borg does not.
2. **It has a real NixOS module**, so the backup is reviewable configuration
   rather than hand-rolled units. Kopia does not.
3. **It separates backup from prune**, which is what makes the restricted
   no-delete credential in §3 work at all.
4. **One tool across every target** — cloud now, a local disk or `rest-server`
   later — means **one restore procedure to test**, and restores are where backup
   plans die.
5. **It scales to the rest of the fleet** if memory-alpha or pegasus ever need
   offsite, without a repo-per-host rule.

The nixpkgs module also ships `createWrapper`, which generates a `restic-<name>`
command with the repository and credentials preloaded. Small, but it is the
difference between a documented restore and a remembered one.

⚠ **The honest cost of choosing restic over borg** is the weaker append-only
story: an IAM policy and object lock you configured, rather than a server that
refuses deletes by design. §3 says to verify that policy rather than assume it.
That is the one place this recommendation should be revisited if it does not hold
up in practice.

### All three fix the thing that annoys about iDrive

The owner's other iDrive friction is key handling. Consumer backup products
typically bind the data to the key such that **rotating it means re-uploading
everything**, and degrade their web restore when private-key encryption is on.

restic, borg and kopia all avoid this by construction: the repository is
encrypted with a master key, and the passphrase merely *wraps* it. So
`restic key add` / `restic key passwd`, or `borg key change-passphrase`, rotate
credentials in milliseconds without touching a byte of stored data. This is not a
discriminator between the three — it is a reason all three beat the status quo.

NixOS has `services.restic.backups.<name>`; nothing in this fleet uses it yet.

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

- **Size the Critical and Precious tiers** (§3) — against the 500 GB ceiling
  rather than to choose a mechanism, which is now settled.
- **Choose the provider** — e2 or B2; restic makes the choice reversible, so this
  is not a decision to agonise over. Decide on key-scoping support, not price.
  ⚠ Proton Drive was evaluated and rejected (§4) — no scoped credentials.
- **Verify the no-delete key actually works** with restic on the chosen provider
  (§3). This is the security-relevant one.
- **Design key custody** (§5) *before* the first backup runs, not after.
- **Wire the three signals** (§3b) — Kuma push monitor for the heartbeat, ntfy
  for the budget thresholds, `RequiresMountsFor=` so an unmounted source cannot
  produce a green empty backup. Plus the quarterly restore-test nag.
- ~~**Decide on physical rotation for Tower.**~~ **Closed 2026-08-07** — the
  500 GB cloud budget makes it unnecessary. Kept in §6 as the fallback if the
  Precious tier ever outgrows the budget by more than it is worth paying for.
- **Survey memory-alpha, hopper and hamilton.** They are blank in §2 because
  nobody has looked, not because they are known to have nothing.
