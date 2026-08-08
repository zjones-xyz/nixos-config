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

### 🔒 Requirement: the vendor must not be able to decrypt the data

**Owner, 2026-08-07.** Stated as a hard requirement, and it is worth recording
prominently because it looks like it should drive the provider choice and
actually does the opposite.

**All three candidate tools already satisfy it, by construction.** restic, borg
and kopia encrypt on the client, before anything leaves the host. The provider
receives opaque blobs and no key material — not a promise, not a policy, a
property of where the encryption happens.

**So this requirement is orthogonal to the provider.** Once the payload is
ciphertext the storage vendor's trustworthiness stops being load-bearing, which
means the provider can be chosen on price and key-scoping (§3) with no privacy
compromise at all. **You do not need a privacy-branded vendor, because you are
not trusting the vendor with privacy.**

⚠ **This is why Proton Drive is the wrong answer to this specific concern**, not
the right one. Proton's end-to-end encryption is real, but the key is derived
from your account password and managed inside Proton's own key infrastructure by
Proton's own client code. With restic you generate a passphrase that never
leaves your control, and the tool that uses it is open source, pinned by hash in
this flake, and built from source. **Holding the key yourself is strictly
stronger than a vendor holding it on your behalf and promising not to look** —
and it costs the credential-scoping problem in §4's Proton section to get the
weaker version.

**This is one of the owner's standing complaints about the iDrive subscription**,
confirmed 2026-08-07 — and the two complaints turn out to be the same complaint.

Consumer backup products offer zero-knowledge as an *optional mode with penalties
attached*: turn on private-key encryption and the web restore degrades, the
key becomes unrotatable without re-uploading, and assisted recovery stops being
available. That is not a badly built feature. **It is the honest expression of a
tradeoff that cannot be avoided**: a vendor cannot both help you restore and be
unable to read your data. Every feature that justifies the subscription — browse
in a browser, support-assisted recovery, courier restore — needs the key.

restic has no such tension because there is no vendor-side feature to disable.
Zero-knowledge is the only mode, so nothing degrades by choosing it, and key
rotation is cheap because the passphrase only ever wrapped a master key.

> ⚠ **The cost is real and worth naming: you become your own recovery vendor.**

That is what elevates §5 from good practice to *the thing that replaces a service
you were paying for*. Nobody can be called when the passphrase is lost. Nobody
verifies the archive is restorable but you. The fireproof-box key copy and the
from-zero restore test are not paranoia — they are the in-house replacement for
the support line you are giving up, and they are the reason this trade comes out
favourably rather than merely cheaper.

Three honest caveats:

- **Metadata still leaks a little.** The provider sees total volume, upload
  cadence and when the repository was last touched. It does **not** see filenames,
  directory structure or individual file sizes — restic stores everything in
  opaque fixed-ish pack files with random names, which is if anything better
  metadata hygiene than a vendor that encrypts a *filesystem* and therefore knows
  its shape. Traffic analysis remains possible and is almost certainly irrelevant
  to this threat model.
- **The property depends on holding the key** — which makes §5's key custody
  problem load-bearing for privacy as well as recovery. They are different axes:
  losing the key costs you the data, and leaking it costs you the privacy.
- **restic's construction is conventional**, not novel — AES-256-CTR with a
  Poly1305-AES MAC, content-addressed. It has had public scrutiny. ⟨If the exact
  audit history matters to the decision, read it directly rather than taking this
  sentence's word for it.⟩

**NixOS strengthens the claim** rather than merely permitting it: the binary
comes from a pinned, hash-verified source built through the flake, not from an
auto-updating vendor client that could change what it does with your key between
one release and the next. That is a real difference from every consumer backup
product, iDrive included.

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

### ⚠ borgmatic reopens this — verified 2026-08-07

**The owner recalled a tool that plugs into MariaDB and Postgres and integrates
with borg or restic. It is `borgmatic`, and the recollection is right except for
"or restic".** Checked against the pinned tree (**borgmatic 2.1.6**, with a
`services.borgmatic` NixOS module exposing `settings` and `configurations`):

**Native data-source hooks shipped:**
`postgresql.py`, `mariadb.py`, `mysql.py`, `sqlite.py`, `mongodb.py`.

**Native monitoring hooks shipped:**
`ntfy.py`, `uptime_kuma.py`, `healthchecks.py`, `cronitor.py`, `cronhub.py`,
`pagerduty.py`, `pushover.py`, `apprise.py`, `loki.py`, `sentry.py`, `zabbix.py`.

❌ **It is borg-only.** Grepping its entire Python source for "restic" returns
nothing. There is no backend abstraction; the name is not a coincidence.

**This matters because borgmatic natively does two of the messiest things in this
document.** §4d's database dumps — including *streaming* them into the archive,
so there is no intermediate file, no dump-then-backup ordering constraint, no
retention to manage on dump files, and no chance of the pre-compression footgun.
And §3b's monitoring — with hooks for **exactly the two services this fleet
already runs on hopper**.

⚠ **I framed borg's advantage as server-side append-only. That was the smaller
half.** The larger half is that borgmatic turns most of §3b and §4d from
hand-rolled systemd units into configuration. That is a correction of emphasis,
not of fact — every fact above still stands — but it materially rebalances the
recommendation below.

### The decision is now genuinely close, and hinges on one axis

| | **restic + wrapper** | **borg + borgmatic** |
|---|---|---|
| **Storage** | ✅ S3/object — iDrive e2, B2, anything; provider swappable | ❌ SSH only — rsync.net, BorgBase, Hetzner Storage Box |
| **Database handling** | Write it: `pg_dump \| restic backup --stdin`, plus ordering and retention | ✅ Native, streamed, with restore |
| **ntfy + Uptime Kuma** | Write the `curl` calls | ✅ Native hooks |
| **Append-only** | Object lock / IAM policy you configure | ✅ Server-enforced |
| **Config surface** | `services.restic.backups.*` + glue | ✅ One YAML, one module |
| **Restic wrappers packaged** | `autorestic` 1.8.3, `resticprofile` 0.31.0, `backrest` 1.14.1 | — |

The restic wrappers all offer *generic* before/after hooks, so a database dump is
perfectly achievable — `restic backup --stdin` even streams it, avoiding the
intermediate file the same way. **The difference is native versus scripted**, and
scripted means the correctness of §4d is yours to maintain.

**So the question reduces to:** is object storage worth writing the glue?

- **Object storage matters more** → restic. Keeps iDrive e2 live, keeps the
  provider swappable, and the glue is a few dozen lines you control.
- **Turnkey matters more** → borgmatic, on an SSH-based host. Accept a smaller
  provider set — rsync.net has borg-specific plans, BorgBase is purpose-built,
  Hetzner Storage Boxes are cheap — and get databases, monitoring, retention and
  check scheduling as configuration. ⟨Verify current pricing; it moves.⟩

⚠ **Note what this does to §4b's sequencing.** Choosing borgmatic means iDrive e2
is off the table permanently, so the eight-months-left subscription becomes purely
a wind-down for the desktops rather than a possible shared destination. That is
not an argument either way, but it should be a conscious consequence rather than
a discovered one.

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

⚠ **The honest cost of choosing restic over borg is now larger than first
written.** It is not only the weaker append-only story — an IAM policy and object
lock you configured, rather than a server that refuses deletes by design. It is
also that §4d's database handling and §3b's monitoring become code you write and
maintain, where borgmatic ships both. **This recommendation is no longer clear-cut**
and should be re-taken deliberately against the table above rather than inherited
from an earlier draft that had not found borgmatic.

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

## 4b. Sequencing — the iDrive subscription has eight months left

**Owner, 2026-08-07:** eight months remain (so renewal falls around **2027-04**),
there is spare capacity for pegasus to use it too, and the intent is to hold off
moving the desktops to restic for roughly **5–6 months**.

**Deferring the desktops is sound, and it is sequencing rather than
procrastination.** Tower cannot use the subscription at all — that was the
original objection — so Tower moves to restic now regardless. By the time the
desktop decision comes up there will be five or six months of operational
experience with restic on a real workload, including at least two quarterly
restore tests (§3b). That is exactly the evidence the decision wants, and it
cannot be gathered any faster.

### ⚠ But the logic inverts for pegasus

Deferring is free where iDrive is *already working* and switching is the cost.
That describes **serenity**: the client is installed, the subscription is live,
and moving it to restic is effort spent to replace something functioning.

**It does not describe pegasus, which has no offsite copy at all today (§2).**
There, *adopting* iDrive is the effort, and it is effort discarded at renewal:

- ⚠ **iDrive's Linux client is not in nixpkgs.** Checked directly —
  `nix eval nixpkgs#idrive` resolves to nothing. Getting it onto a NixOS host
  means an FHS wrapper around a vendor script bundle, plus imperative state
  outside the flake. That is precisely the shape `DESIGN.md` §3.2 gives as the
  reason for this whole migration.
- **restic on pegasus is a `services.restic.backups.<name>` block** — declarative,
  reviewed in a PR, and sharing its configuration shape with Tower's.
- **The marginal storage cost is small.** A desktop's backup scope is a home
  directory and some config, not a photo library.

**So the recommendation is: defer serenity as planned, and put pegasus straight
onto restic alongside Tower.** It closes pegasus's gap sooner, with the tooling
that is being kept rather than the tooling being retired.

⟨Owner's call. The counter-argument is that iDrive capacity is already paid for,
which is true and is a real consideration if pegasus's scope turns out large.⟩

**Repo layout for a second host:** restic supports several hosts writing to one
repository, which buys cross-host deduplication. The alternative is a repo per
host in the same bucket, which trades a little dedup for isolation — pegasus's
key then cannot read Tower's snapshots. Both are defensible in a single trust
domain; decide when pegasus is wired.

### ⚠ Do not let the renewal pass by default

The one scheduling risk worth naming: **if pegasus ends up depending on iDrive
and the subscription lapses before the restic migration happens, pegasus silently
loses its only offsite copy.** Auto-renewal is the benign version; a lapsed card
is not.

**Set a reminder for roughly 2027-02** — about six months out, two months before
renewal. ntfy already exists (§3b) and a one-shot systemd timer or a calendar
entry both work. The point is that the decision gets made deliberately rather
than by the date arriving.

### Timeline

| When | What |
|---|---|
| **Now** (2026-08) | Tower → restic. It has no offsite and cannot use iDrive. |
| **Now** | pegasus → restic *(recommended)*, or iDrive if the paid capacity wins |
| **~2027-02** | ⚠ Reminder fires. Decide on serenity with five months of restic evidence in hand |
| **~2027-04** | iDrive renewal. Renew or lapse — deliberately |

Serenity is under no pressure in any of this: it has three working offsite paths
and is the best-covered machine in the fleet (§2).

## 4c. Can bind mounts be tagged for backup handling in Compose?

**Evaluated 2026-08-07. Directly: no. Usefully: yes, one indirection away — and
for most of this fleet there is a better answer than either.**

### The literal answer

**A bind mount is not a Docker object.** It is a path mapping recorded on the
container, so there is nothing to attach metadata to. `labels:` exists on
*services* and on *named volumes*, and neither covers `- /host/path:/container/path`.

### The workable pattern: label the service, derive the mounts

Put the intent on the service and let Docker tell you the paths:

```yaml
services:
  immich-server:
    labels:
      backup.tier: precious
      backup.stop: "true"      # quiesce before snapshotting a database
```

```sh
# tier + host path, one per line, for every labelled container
docker ps --filter "label=backup.tier" -q \
| xargs docker inspect --format \
  '{{$t := index .Config.Labels "backup.tier"}}{{range .Mounts}}{{if eq .Type "bind"}}{{$t}} {{.Source}}
{{end}}{{end}}'
```

That feeds straight into `restic --files-from`. Prior art exists rather than
needing invention — `offen/docker-volume-backup` drives off labels like
`docker-volume-backup.stop-during-backup`, and `nautical-backup` is the
Unraid-ecosystem version aimed at exactly this appdata problem.

### ⚠ But it has a failure mode this document already cares about

**Deriving paths from `docker inspect` means a stopped container drops silently
out of the backup.** That is §3b's third signal all over again: the run succeeds,
the heartbeat pings, the repo does not grow, and the thing you stopped "just for
a minute" three weeks ago is quietly unprotected.

Any label-driven scheme needs the path list reconciled against an expected set,
or it fails open.

### The better answer where Nix owns the Compose file

This fleet renders Compose files from Nix — `traefik.nix`, `dockge.nix` and
`arcane.nix` all use `pkgs.writeText` and shell out to `docker compose`. Where
that is true, **round-tripping tier information through Docker labels means
writing it in Nix, rendering it into a label, and then reading it back out at
runtime.** Nix already has it.

Declaring the tier in Nix and emitting *both* the Compose file and the restic
path list from one attribute set is simpler, has a single source of truth, and —
the part that matters — **does not depend on the container running.** The path
list is static, so a stopped service cannot silently vanish from the backup.

### So the split is about ownership, not preference

| Who owns the Compose file | Right mechanism |
|---|---|
| **Nix** (`modules/nixos/*.nix`, `writeText` + `docker compose`) | Declare the tier in Nix; generate the path list alongside the Compose file |
| **Dockge / hand-managed** (`homelab-stacks`, Unraid templates) | Labels are the only in-band option — Nix does not own those files |

Tower today is the second case; Tower after the migration is intended to be the
first. **So labels are the right tool for the transition and the wrong tool for
the destination**, which is worth knowing before building much on them.

Labels retain one job Nix cannot do: **runtime coordination**, such as "stop this
container before snapshotting its database" (`hosts/galactica/SHARES.md` §3 on
`appdata`). Even that can be declared in Nix — but only for services Nix owns.

⟨Revisit once the `appdata` per-container pass has run. That pass produces the
tier-per-container mapping this section is about *expressing*, and doing it in the
wrong order means inventing a schema before knowing what it has to carry.⟩

## 4d. Databases — a file-level backup of a running database is not a backup

**The single most common way a backup turns out worthless.** restic walks the
filesystem and copies files as it finds them; a database writing during that walk
yields a mixture of old and new pages. The result restores cleanly, mounts
cleanly, and fails later — often much later, and often only on the rows you
needed.

Tower's `appdata` holds several: Immich on PostgreSQL, the *arr stack and
Audiobookshelf on SQLite, BookLore and PartDB on MySQL/MariaDB.

### The three approaches, best first

**1. Dump natively, then back up the dump.** Correct, portable, verifiable.

```sh
# PostgreSQL — plain SQL, NOT -Fc. See the compression warning below.
docker exec immich_postgres pg_dumpall -U postgres --clean --if-exists > immich.sql

# MySQL / MariaDB
docker exec booklore_db mysqldump --single-transaction --all-databases > booklore.sql

# SQLite — online, consistent, and no downtime at all
sqlite3 /path/to/app.db ".backup '/var/backup/app.db'"
```

⚠ **SQLite's `.backup` (and `VACUUM INTO`) are online-safe.** They take a
consistent copy of a live database without stopping the application. That means
the entire *arr stack and Audiobookshelf need **no downtime** — which removes most
of the reason to stop containers at all.

**2. Stop the container, copy, start.** Always correct, costs downtime. The right
fallback for anything whose dump path is unclear.

**3. A btrfs snapshot of the data directory, then back up the snapshot.**
Crash-consistent, not application-consistent — equivalent to pulling the power.
Postgres and SQLite-in-WAL-mode are both designed to recover from exactly that,
so this is defensible rather than reckless, and the Services pool is btrfs so it
is available. ⚠ But it only holds if the whole data directory is captured
atomically in one snapshot; a database spanning subvolumes loses the guarantee
silently.

**4. Never: `cp`, `rsync` or `restic` straight over live database files.** This is
the default behaviour if nobody intervenes, which is why it is the common failure.

### ⚠ Do not compress dumps before handing them to restic

Non-obvious and expensive to get wrong. **restic deduplicates with content-defined
chunking, which needs the input to change only where the data changed.** A
compressed dump changes in its entirety when one row changes — gzip and zstd
output diverge globally from a small input delta.

So a nightly `pg_dump | gzip` stores a **full copy every night**, while a nightly
plain-text `pg_dump` stores roughly the delta. On a 500 GB budget with a
years-long retention window, that is the difference between a rounding error and
the dominant line item.

- **PostgreSQL:** use plain format (`-Fp`, the default for `pg_dump`). ⚠ `-Fc`
  custom format compresses by default — pass `-Z0` if you want it.
- **MySQL/MariaDB:** plain `mysqldump` output is already text. Do not pipe it
  through `gzip`.
- **Let restic compress**, which it has done natively with zstd since 0.14.

### Dumps are also the migration mechanism, not just the backup

A PostgreSQL *data directory* is bound to its major version, its build, and its
extension set. A `pg_dump` is portable text.

Since Tower is moving from Unraid's Docker to NixOS's, **the dump discipline this
section describes is the same discipline the migration needs.** Getting it working
now is not overhead ahead of the move — it is the move's prerequisite, exercised
early and repeatedly on a system that still works.

⚠ **Immich's PostgreSQL is the one to be careful with.** It depends on a vector
extension, and restoring a dump requires a compatible extension version present in
the target. This is a documented sharp edge with its own upstream guidance —
**follow Immich's own backup and restore documentation for that database rather
than a generic `pg_dumpall` recipe**, and test the restore before relying on it.
It is Precious-adjacent data (§3), so it deserves the extra care.

### What NixOS gives you, and what it does not

The pinned tree ships `services.postgresqlBackup`, `services.mysqlBackup`,
`services.automysqlbackup` and `services.pgbackrest`. ⚠ **All of them target
host-native database services, not containerised ones**, so none applies directly
to a Docker-hosted Immich or BookLore.

The pattern is still worth mirroring: a systemd timer dumps into a directory,
restic backs up that directory, and the dumps carry their own small retention so
the directory does not grow without bound. Ordering matters — **the dump timer
must complete before the restic run starts**, or the backup captures yesterday's
dump and reports success.

⟨Feeds the `appdata` per-container pass (`hosts/galactica/SHARES.md` §3): each
container needs a verdict on which of the three approaches applies, and that is
the same pass that assigns its tier.⟩

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
  is not a decision to agonise over. Decide on key-scoping support, not price,
  and **not on the vendor's privacy claims** — client-side encryption makes those
  irrelevant (§4). ⚠ Proton Drive was evaluated and rejected (§4): its E2EE is the
  weaker form of a property restic already provides, and it offers no scoped
  credentials.
- **Verify the no-delete key actually works** with restic on the chosen provider
  (§3). This is the security-relevant one.
- **Design key custody** (§5) *before* the first backup runs, not after.
- **Set the 2027-02 renewal reminder** (§4b) so the iDrive decision is made
  deliberately rather than by the date arriving.
- **Decide pegasus's target** (§4b) — restic now, or iDrive until renewal.
- **Work out a dump path per database** (§4d) before the first backup runs. A
  file-level copy of a live database is the most common way a backup turns out
  worthless, and it is also the migration's prerequisite.
- **Wire the three signals** (§3b) — Kuma push monitor for the heartbeat, ntfy
  for the budget thresholds, `RequiresMountsFor=` so an unmounted source cannot
  produce a green empty backup. Plus the quarterly restore-test nag.
- ~~**Decide on physical rotation for Tower.**~~ **Closed 2026-08-07** — the
  500 GB cloud budget makes it unnecessary. Kept in §6 as the fallback if the
  Precious tier ever outgrows the budget by more than it is worth paying for.
- **Survey memory-alpha, hopper and hamilton.** They are blank in §2 because
  nobody has looked, not because they are known to have nothing.
