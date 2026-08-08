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

### ✅ Budget: 950 GB at BorgBase — physical rotation is off the table

**Owner, 2026-08-07**, revised **2026-08-08** to **950 GB on BorgBase**. That
settles the mechanism question that sizing was gating, and it settles it toward
the simpler answer: **cloud only, no drive swap, no new habit.**

> **Revised from 500 GB.** The original figure was set against commodity
> object-storage rates (~$6/TB/month, iDrive e2 or B2). Choosing borg + borgmatic
> (§4) took object storage off the table entirely — borg speaks SSH — so the
> pricing shape changed with the provider. 950 GB sits just under a 1 TB plan,
> leaving headroom rather than budgeting to the exact quota, which is the right
> way round: **hitting a hard quota mid-run fails the backup, and §3b's budget
> signal exists precisely so that never happens by surprise.**

⟨Take the actual monthly figure from BorgBase's current plan page rather than
from this document — it is not something to record here and let rot.⟩

⚠ **Still measure the tiers**, because the budget is a ceiling, not a fit:

```sh
du -sh /mnt/user/immich_photos /mnt/user/immich_photos_archived /mnt/user/documents
```

**Expect the stored size to be close to the source size.** borg dedups and
compresses, but photos are already-compressed JPEG/HEIC and will store at roughly
1:1. `documents` may compress well, and it is small either way. So plan as though
950 GB of budget buys about 950 GB of photos.

If the Precious tier overflows the budget, the options in preference order are:
raise the budget (BorgBase sells larger plans), cloud the newer material and
leave the deep archive to the scattered-but-extant originals (§3), or reintroduce
rotation for the overflow only.

### ⚠ Cloud-only loses the air-gap — `borg serve --append-only` buys most of it back

Serenity's rotated drives are air-gapped by construction: a compromised machine
cannot reach a disk sitting in another building. Cloud-only gives that up, and
the specific scenario is that something with root on Tower deletes the backups
before anyone notices.

> ⚠ **Rewritten 2026-08-07 for borg (§4).** An earlier revision built this around
> S3 scoped keys and object lock, which no longer applies — borg speaks SSH, not
> object storage. The replacement is **stronger**, which is part of why borg was
> chosen.

**Do not let Tower hold a credential that can delete.** With borg this is enforced
by the *server* rather than by a policy you configured correctly:

- **`borg serve --append-only`** lets a client add archives and forbids removing
  them. Pinned in the provider's `~/.ssh/authorized_keys` as a forced command, so
  the client cannot opt out:

  ```
  command="borg serve --append-only --restrict-to-repository /path/to/repo",restrict ssh-ed25519 AAAA…tower
  ```

- **Prune from elsewhere, rarely** — a second SSH key *without* `--append-only`,
  living on the admin machine and never on Tower.

**This is a real guarantee rather than an approximation.** The restic plan relied
on an IAM policy plus object lock, i.e. on having written the policy correctly
and on the provider honouring it. Here the storage server simply refuses the
operation, and the refusal is visible in `authorized_keys`.

✅ **Provider decided 2026-08-08: BorgBase**, which is the option that exposes
append-only as a **per-key toggle in its own UI** rather than as an
`authorized_keys` line you hand-maintain. Append-only support was the genuine
differentiator here — rsync.net documents it too, and a Hetzner Storage Box left
it needing confirmation — so this closes the property §3 is built on.

⚠ **Still verify it end to end before trusting it.** A toggle in a web UI is a
claim, and the test is cheap: with the append-only key configured, attempt a
`borg delete` or a `borgmatic prune` from Tower and confirm the *server* refuses.
Passing that test is what makes the paragraph above true; assuming it is what
makes it decorative.

**Two consequences worth noting now that the provider is known:**

- **Prune has to run from somewhere else.** With Tower's key append-only, retention
  cannot be enforced by Tower. Use a second BorgBase key without the toggle, kept
  on the admin machine, and run prune deliberately rather than nightly.
- **BorgBase has its own inactivity alerting**, independent of the fleet's
  monitoring. That is worth turning on *in addition to* the Kuma heartbeat (§3b),
  precisely because it does not run on hopper — it survives the fleet being down,
  which is the case a self-hosted watcher cannot cover. ⟨Confirm the exact
  alerting options on the current plan.⟩

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

**2. Budget — is the repo approaching 950 GB?**

After each run, `borg info` reports the repository's deduplicated size; compare it
against thresholds and post to ntfy with escalating priority — 80% informational,
90% high, 100% urgent.

⚠ borgmatic's native `ntfy` hook fires on run **success and failure**, not on a
size threshold, so this specific signal is still a small script. It can hang off
borgmatic's `after_backup` command rather than a separate timer.

**3. ⚠ Did the backup contain anything? — the failure that defeats both above**

If a source path exists but its filesystem is not mounted, borg will happily
archive an empty directory, **exit 0, fire the success hook, and not grow the
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

**Versions in this flake's pinned nixpkgs** (rev `3497aa5c`): `restic`
**0.18.1**, `borgbackup` **1.4.4**, `borgmatic` **2.1.5**, `kopia` **0.23.0**,
`rclone` **1.74.2**.

> ⚠ **Corrected 2026-08-08.** This section previously claimed these had been
> "evaluated rather than recalled" and gave every one of them **one patch level
> too high** — 0.19.1 / 1.4.5 / 2.1.6 / 0.23.1 / 1.74.4. They were recalled. The
> figures above come from `nix eval` against the locked rev, and the systematic
> off-by-one is the tell: a real evaluation does not miss in one direction five
> times. Note that `snapraid` **14.4** in `hosts/galactica/DESIGN.md` — the one
> version that *was* checked deliberately — is correct. **No argument in this
> document turns on a patch level**, so nothing downstream changes; the claim of
> provenance was the actual defect.

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

| | restic 0.18.1 | borg 1.4.4 | kopia 0.23.0 |
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

Checked against the rclone shipped in this flake's pinned nixpkgs (**1.74.2**),
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

### Key custody — a difference borg can configure away

§5 requires a copy of the credential that survives losing every machine. restic's
model is **one secret**: the repository password, which unwraps the master key, so
the fireproof-box copy is a passphrase on paper.

Borg has two modes and only one of them matches that. **`repokey` is equivalent
to restic** — key in the repository, passphrase protects it, one secret. **`keyfile`
splits custody in two**: the key lives in `~/.config/borg/keys` on the client and
the passphrase protects *it*, so losing the machine loses the key even if the
passphrase is remembered. Borg ships `borg key export --paper` precisely because
that failure is real.

**So this is not a reason to prefer either tool — it is a setting to get right
once**, at repository creation. See the decision below.

All three rotate credentials cheaply, which is the property that fixes the iDrive
annoyance (below).

### ⚠ borgmatic reopens this — verified 2026-08-07

**The owner recalled a tool that plugs into MariaDB and Postgres and integrates
with borg or restic. It is `borgmatic`, and the recollection is right except for
"or restic".** Checked against the pinned tree (**borgmatic 2.1.5**, with a
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

### ✅ Decision: borg + borgmatic

**Owner, 2026-08-07: "borgmatic seems like it'll have less sharp edges."**
Agreed, and the earlier restic recommendation is superseded — it was written
before borgmatic was found and rested on a comparison that undercounted what borg
brings with it.

**What the choice removes**, all of which was otherwise code to write and own:

- Database dumps for Postgres, MariaDB/MySQL and SQLite, **streamed into the
  archive** — no intermediate file, no dump-before-backup ordering constraint, no
  retention policy on dump files.
- The §4d pre-compression footgun, which cannot be stepped on because there is no
  step where you would compress.
- The ntfy and Uptime Kuma calls in §3b, both native hooks.
- Retention, consistency-check scheduling, and restore of individual databases.

**What the choice costs, and it is now a live decision rather than a footnote:**

⚠ **A storage provider must be chosen, from a smaller set, and iDrive e2 is
permanently out.** borg needs SSH to a host running `borg serve`. The realistic
options were **rsync.net** (borg-specific plans), **BorgBase** (purpose-built),
or a **Hetzner Storage Box**.

✅ **Resolved 2026-08-08: BorgBase**, at a 950 GB budget (§3). Append-only was
the deciding property — it is *server-side*, it is the ransomware protection borg
was picked partly for, and BorgBase exposes it as a per-key toggle rather than an
`authorized_keys` line to hand-maintain.

### ⚠ Sharp edges this does not remove — and one it adds

Worth naming now rather than discovering later.

**1. Use `repokey`, not `keyfile`, at repository creation.** This is the one edge
borg has that restic does not. In `keyfile` mode the encryption key lives in
`~/.config/borg/keys` on the client and the passphrase merely protects it — so
losing the machine loses the key even if you remember the passphrase. `repokey`
stores the key in the repository, protected by the passphrase, which collapses
custody to **one secret** and matches what §5's fireproof-box copy assumes.

Borg ships `borg key export --paper` precisely because `keyfile` mode's two-part
custody bites people. Choosing `repokey` means never needing it.

**2. §5's key-custody circularity is unchanged.** borgmatic does not help here.
The passphrase still has to survive an event that takes both Tower and Serenity,
and the from-zero restore test is still the only thing that proves it.

**3. One client per repository.** Borg is emphatic about this; concurrent clients
against one repo is a known footgun. So **pegasus gets its own repository**, which
also means no cross-host deduplication. That is a change from the restic plan in
§4b, where sharing a repo was an option worth weighing.

#### ⚠ Repos are unlimited at BorgBase — that is not a reason to use one per service

Asked 2026-08-08: BorgBase does not charge per repository (billing is on stored
bytes), so should each backed-up service get its own?

**Per-*host* is forced** — that is point 3 above, a borg constraint rather than a
choice. **Per-*service* within a host is a net loss**, and the argument that most
recommends it does not survive contact with this architecture:

- ⚠ **The blast-radius argument dissolves here.** A scoped append-only key per
  service sounds like real containment — a compromised service could only append to
  its own repo. But **borgmatic runs as root on the host, not inside the
  containers**, so a compromised container never holds a borg key at all. Splitting
  buys no containment against the threat it appears to address.
- **Deduplication is per-repository.** Borg dedupes within a repo and never across
  them, so N repos are N dedup domains. Against a **950 GB** budget that is a direct
  cost — modest for genuinely distinct data, real for `appdata` subtrees that share
  base images and near-identical SQLite and config structure.
- ⚠ **Monitoring multiplies, and it fails toward silence.** §3b's heartbeat works
  because a run that does not happen trips the alarm. That needs one monitor per
  repo — and **a monitor that was never created is a gap nothing reports.** The
  failure mode of per-service is a service quietly not being backed up for months.
- **N repos need N passphrases** to keep the isolation that motivated the split,
  multiplying §5's unresolved custody circularity by N. Sharing one passphrase
  across them gives the isolation back.
- **Prune runs from the privileged side** under the no-delete design above, so N
  repos means N prune jobs scheduled and monitored somewhere else.

⚠ One mechanical note, since it is easy to misread the config format: borgmatic's
`repositories:` list inside a single config means *mirror these same sources to all
of them*, *not* different sources per repo. Per-service would need separate files
under `/etc/borgmatic.d/`. That part is clean — it is the operational surface, not
the mechanism, that costs.

#### ✅ Decision: split by churn and retention — a **hot** and a **cold** repo

Owner's call, 2026-08-08. The boundary is *size and churn*, not service:

| Repo | Contents | Why separate |
|---|---|---|
| **hot** | documents, database dumps, config | Small, high churn, long *versioned* retention, runs nightly |
| **cold** | `immich_photos` and friends | Hundreds of GB, near-immutable, needs far fewer versions |

**The operational reason is `check` and `prune`, which walk the whole chunk
index.** Mixing hundreds of GB of near-immutable photos with nightly dumps drags
the photo archive through every integrity check and every prune, forever. The
boundary also falls out of the tier work in `SHARES.md` §5 for free, since Critical
and Precious already differ in exactly these properties.

⚠ **It is not "two repos per host" — it is hot everywhere, cold only where a large
near-immutable tier exists.** On present knowledge that is Tower alone:

| Host | Repos | Note |
|---|---|---|
| galactica / Tower | `tower-hot`, `tower-cold` | The immich shares are the only cold tier in the fleet |
| pegasus | `pegasus-hot` | No large immutable tier known; add cold only if the survey finds one |
| memory-alpha | `memory-alpha-hot` | ⚠ scope **unsurveyed** — see below |

**Four repos, not six.** Add a cold repo when a host actually grows one, rather
than provisioning empty ones — an empty repo still needs a heartbeat, and a
heartbeat on a repo that legitimately never grows is a monitor that can only ever
cry wolf.

**What this decision now owes:** the two repos exist *to have different retention*,
so leaving both on one policy would spend the operational cost and buy nothing.
Concrete `keep-daily`/`keep-weekly`/`keep-monthly` numbers per class are still
unwritten — recorded in §6.

⚠ **It costs nothing for the memory-alpha and pegasus work starting now**, since
both are hot-only. The split only bites when Tower arrives, which is the right time
to be thinking about the photo archive anyway.

#### The mobility argument — the real motivation, and it deserves a better answer

Clarified 2026-08-08: the case for per-service repos was never blast radius or
retention. It was that **a repo per service makes a service easy to move between
hosts** — point the new host at the same repo and the history continues. The
analysis above answered a question that had not been asked.

**The concern is legitimate, and it names a real hazard.** With per-host repos, a
service that moves from Tower to memory-alpha leaves its history in `tower-hot`
while new archives land in `memory-alpha-hot`. Split history is merely annoying —
⚠ **but `tower-hot`'s prune policy keeps running, so the pre-move history ages out
on schedule.** A service moved in January silently loses its 2026 backups in April.
That failure is quiet, and nothing in the monitoring design would report it.

**But repo-per-service is not what makes a service portable — the config is.**
What actually has to travel with a service is its *source-path definition*: which
`appdata` subtree, which data shares, which database and its dump command. Put that
in **`/etc/borgmatic.d/<service>.yaml`**, one file per service, and moving a service
becomes: copy one file to the new host, change the `repositories:` line. That is
portable whether or not the repo is shared, and it is worth doing regardless.

**And a service stays addressable inside a shared repo** via `archive_name_format`.
Prefix archives with the service rather than the host and
`borg list --glob-archives 'partdb-*'` recovers exactly that service's timeline out
of a repo holding a dozen others. Per-service granularity for *restore* does not
require per-service repos; it requires naming discipline.

#### ✅ Decision: hot/cold repos, **per-service borgmatic configs**

Owner's call, 2026-08-08. The repo layout stays hot/cold; the *unit of
configuration* is the service.

| Want | Mechanism |
|---|---|
| Move a service between hosts | per-service `/etc/borgmatic.d/<service>.yaml` |
| Restore one service from a shared repo | `archive_name_format` prefixed with the service |
| Keep pre-move history | ⚠ **nothing automatic** — see below |

⚠ **`archive_name_format` is load-bearing here, not cosmetic — getting it wrong
deletes data.** Several configs write into one repo and each runs its own prune.
borgmatic scopes prune and check to the archives matching a config's
`archive_name_format` (deriving `match_archives` from it), and that is exactly what
keeps `partdb`'s prune from aging out `immich`'s archives. **So every service needs
a distinct format** — `partdb-{now:%Y-%m-%dT%H:%M:%S.%f}` rather than borgmatic's
`{hostname}-…` default, under which every config on a host produces
identically-shaped names and each prune would consider the others' archives its own.

⚠ **Verify that before trusting it**, rather than on the strength of this
paragraph: the pinned tree ships **borgmatic 2.1.5**, and how `match_archives` is
derived has moved across borgmatic versions. The test is cheap and belongs in the
pilot (§6.6) — write archives from two configs into one repo, run `prune --dry-run`
on one, confirm the other's archives are not listed for deletion. **This is the
single highest-consequence unverified assumption in the backup design**, because
its failure mode is silent deletion of a *different* service's history.

⚠ **The residual risk is real and has no free fix.** When a service moves, decide
deliberately what happens to its history in the old repo: accept the prune window
(usually fine — the overlap is months), or suspend prune on the old repo until the
new one has enough depth to stand alone. **Whichever, decide it at move time**, not
after the archives are gone. Borg cannot move archives between repositories; the
old repo stays readable indefinitely if you simply stop pruning it.

**What keeps this from tipping to per-service is the monitoring cost**, not the
mobility argument, which is sound. Thirty repos is thirty heartbeats, and §3b's
design fails toward silence — the gap that hurts is the monitor nobody created.
Two repos and thirty *config files* gives the portability without that.

**4. borg 2 will eventually mean a repository migration.** Verified: this tree
ships **borgbackup 1.4.4**, and `borgbackup_2` is **not packaged at all**. So borg
2 is a future event rather than an imminent one, and there is no decision to make
today — but it is a known cost that restic does not have pending, and it should
not arrive as a surprise.

### All three fix the thing that annoys about iDrive

The owner's other iDrive friction is key handling. Consumer backup products
typically bind the data to the key such that **rotating it means re-uploading
everything**, and degrade their web restore when private-key encryption is on.

restic, borg and kopia all avoid this by construction: the repository is
encrypted with a master key, and the passphrase merely *wraps* it. So
`restic key add` / `restic key passwd`, or `borg key change-passphrase`, rotate
credentials in milliseconds without touching a byte of stored data. This is not a
discriminator between the three — it is a reason all three beat the status quo.

NixOS has `services.borgmatic` (and `services.borgbackup.jobs.*`, and
`services.restic.backups.*`); **nothing in this fleet uses any of them yet.**

## 4b. Sequencing — the iDrive subscription has eight months left

**Owner, 2026-08-07:** eight months remain (so renewal falls around **2027-04**),
there is spare capacity for pegasus to use it too, and the intent is to hold off
moving the desktops off it for roughly **5–6 months**.

**Deferring the desktops is sound, and it is sequencing rather than
procrastination.** Tower cannot use the subscription at all — that was the
original objection — so Tower moves to borgmatic now regardless. By the time the
desktop decision comes up there will be five or six months of operational
experience with borgmatic on a real workload, including at least two quarterly
restore tests (§3b). That is exactly the evidence the decision wants, and it
cannot be gathered any faster.

### ⚠ But the logic inverts for pegasus

Deferring is free where iDrive is *already working* and switching is the cost.
That describes **serenity**: the client is installed, the subscription is live,
and moving it to borgmatic is effort spent to replace something functioning.

**It does not describe pegasus, which has no offsite copy at all today (§2).**
There, *adopting* iDrive is the effort, and it is effort discarded at renewal:

- ⚠ **iDrive's Linux client is not in nixpkgs.** Checked directly —
  `nix eval nixpkgs#idrive` resolves to nothing. Getting it onto a NixOS host
  means an FHS wrapper around a vendor script bundle, plus imperative state
  outside the flake. That is precisely the shape `DESIGN.md` §3.2 gives as the
  reason for this whole migration.
- **borgmatic on pegasus is a `services.borgmatic.*` block** — declarative,
  reviewed in a PR, and sharing its configuration shape with Tower's.
- **The marginal storage cost is small.** A desktop's backup scope is a home
  directory and some config, not a photo library.

**So the recommendation is: defer serenity as planned, and put pegasus straight
onto borgmatic alongside Tower.** It closes pegasus's gap sooner, with the tooling
that is being kept rather than the tooling being retired.

⚠ Updated 2026-08-07 — this said *restic* before borg + borgmatic was chosen
(§4). The reasoning is unchanged: iDrive's Linux client is not packaged, so
adopting it on a NixOS host is effort discarded at renewal, while borgmatic is
declarative and shares Tower's configuration shape.

⟨Owner's call. The counter-argument is that iDrive capacity is already paid for,
which is true and is a real consideration if pegasus's scope turns out large.⟩

**Repo layout for a second host: decided by the tool.** Borg wants **one client
per repository**, so pegasus gets its own — no decision to make, and no cross-host
deduplication. ⚠ On BorgBase that means **two repositories against the same
950 GB budget**, so pegasus's scope competes with Tower's photos rather than
being free. ⚠ This was an open choice under the restic plan, where several
hosts can share a repository; borg closes it. Budget for two repositories on the
provider rather than one.

### ⚠ Do not let the renewal pass by default

The one scheduling risk worth naming: **if pegasus ends up depending on iDrive
and the subscription lapses before the borgmatic migration happens, pegasus silently
loses its only offsite copy.** Auto-renewal is the benign version; a lapsed card
is not.

**Set a reminder for roughly 2027-02** — about six months out, two months before
renewal. ntfy already exists (§3b) and a one-shot systemd timer or a calendar
entry both work. The point is that the decision gets made deliberately rather
than by the date arriving.

### Timeline

| When | What |
|---|---|
| **Now** (2026-08) | Tower → **borgmatic → BorgBase**, 950 GB. It has no offsite and cannot use iDrive. |
| **Now** | pegasus → borgmatic *(recommended)*, its own BorgBase repo against the same budget, or iDrive if the paid capacity wins |
| **~2027-02** | ⚠ Reminder fires. Decide on serenity with five months of borgmatic evidence in hand |
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

That feeds straight into **`borg create --paths-from-command`** — verified
present in the pinned borg 1.4.4, alongside `--paths-from-stdin` and
`--patterns-from`. Note what that means: borg has a *first-class flag* for
"run this command to decide what to back up", so the pattern below is not merely
possible but frictionless, which is exactly why the failure mode after it is
worth stating loudly. Prior art exists rather than
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

Declaring the tier in Nix and emitting *both* the Compose file and borgmatic's
`source_directories` from one attribute set is simpler, has a single source of
truth, and —
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

### Does "Nix owns the Compose file" imply compose2nix?

**Asked 2026-08-08. Short answer: no — and letting backups drive that decision
would be the tail wagging the dog.**

Both candidates are in the pinned tree, checked rather than assumed:
**`compose2nix` 0.3.3** and **`arion` 0.2.2.0**. Neither is used anywhere in this
flake today — `grep` for `oci-containers`, `arion` and `compose2nix` across every
`.nix` returns nothing.

**What the backup actually requires is weaker than Nix owning the containers.**
The argument above is only that the path list must not be *derived at runtime*,
because a stopped container then drops out silently. Satisfying that needs a
**static declaration** of tier → paths. A plain Nix attrset feeding borgmatic's
`source_directories` does it, without converting a single container.

The real objection to a standalone list is **drift**: someone adds a bind mount
and forgets the backup. But drift is *detectable*, and this section already
demands the check — "reconciled against an expected set, or it fails open." Run
the `docker inspect` pipeline above as an **auditor** rather than as the source,
compare it to the declared list, and alert on divergence via ntfy (§3b). That
inverts the failure mode: a stopped or newly-mounted container makes the check
complain instead of silently shrinking the backup. **You get the drift protection
without the migration.**

#### What compose2nix would actually cost

Worth being precise, because the two tools are not the same kind of thing:

| | `compose2nix` | `arion` |
|---|---|---|
| Kind of tool | **One-shot generator.** Reads a Compose file, emits Nix | **Runtime layer.** Nix is the source, it renders Compose and drives it |
| Output targets | `virtualisation.oci-containers` — i.e. **systemd units, not Compose** | `docker compose`, semantics preserved |
| Re-running it | Regenerates; **hand edits are clobbered** | n/a — the Nix *is* the source |

So compose2nix is a **migration accelerant, not an architecture.** You run it
once, review what it produced, and from then on you own hand-maintained Nix. That
is genuinely valuable for Tower — turning "transcribe ~30 Unraid stacks by hand"
into "generate, then review" is real work saved — but it is a one-time tool and
should be judged as one.

#### ⚠ What decides it is the dashboard question — and Dockge is not the answer to it

> **Corrected 2026-08-08.** An earlier revision of this section said *"the thing
> that actually decides this is Dockge"*, on the assumption that Dockge's web UI
> was a requirement. **The owner is not attached to Dockge** — what is wanted is
> *visibility*, not stack management. That materially weakens the argument, so it
> is restated rather than left standing.

`modules/nixos/dockge.nix` exists so stacks under `homelab-stacks/` can be managed
through a web UI, deliberately *outside* the flake. It does two jobs that are
easy to conflate:

| Job | Who needs it if Nix owns the stacks |
|---|---|
| **Management** — create, edit, start/stop, redeploy | ❌ Nobody. That *is* what Nix takes over, and a PR-reviewed change beats a text box |
| **Visibility** — what is running, what is unhealthy, what is eating RAM | ✅ Still wanted, and unrelated to who owns the definitions |

**So the split is clean: Nix absorbs the half Dockge exists for, and the half that
remains is monitoring — which is Beszel's job, not Dockge's.** Beszel already runs
in the fleet (`modules/nixos/beszel.nix`, hub + agent on hopper), so the hub
exists and galactica needs only an agent. This is the direction the owner
identified, and it holds up.

⚠ **The trap, verified against the pinned tree:
`virtualisation.oci-containers.backend` defaults to `"podman"`.** Beszel's agent
watches a **Docker** socket (`/run/user/1000/docker.sock` on hopper). So
compose2nix output, taken at its default, produces containers that are *invisible
to the monitoring that was the reason for doing it*. Set `backend = "docker"`
explicitly, or point the agent at podman's socket — but decide it deliberately,
because the failure is silent and looks like "the dashboard is broken".

**The gap Beszel does not close is logs.** It is a metrics tool. Under
`oci-containers` container logs land in the journal
(`journalctl -u docker-<name>`), which is arguably an upgrade — greppable,
rotated, and collected the same way as everything else on the host — but there is
no web view. If one is wanted, that is a separate small service (Dozzle is the
usual answer), not a reason to keep Dockge.

**One genuine side-benefit, recorded so it is not overclaimed:** under
`oci-containers` each container is a systemd unit, which makes `RequiresMountsFor=`
and `OnFailure=` available per container — directly useful against §3b's
empty-backup failure mode. That is a nudge, not a reason.

**Recommendation:** decide container management on its own merits, after the
`appdata` pass. For backups, declare the tiers in Nix and add the reconciliation
check. If compose2nix later earns its place as a migration tool, the tier
declaration written now survives unchanged — it names paths, not container
runtimes.

⟨Revisit once the `appdata` per-container pass has run. That pass produces the
tier-per-container mapping this section is about *expressing*, and doing it in the
wrong order means inventing a schema before knowing what it has to carry.⟩

## 4d. Databases — a file-level backup of a running database is not a backup

**The single most common way a backup turns out worthless.** borg walks the
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

**4. Never: `cp`, `rsync` or `borg` straight over live database files.** This is
the default behaviour if nobody intervenes, which is why it is the common failure.

### ⚠ Do not compress dumps before handing them to borg

Non-obvious and expensive to get wrong. **borg deduplicates with content-defined
chunking, which needs the input to change only where the data changed.** A
compressed dump changes in its entirety when one row changes — gzip and zstd
output diverge globally from a small input delta.

So a nightly `pg_dump | gzip` stores a **full copy every night**, while a nightly
plain-text `pg_dump` stores roughly the delta. On a 950 GB budget with a
years-long retention window, that is the difference between a rounding error and
the dominant line item.

- **PostgreSQL:** use plain format (`-Fp`, the default for `pg_dump`). ⚠ `-Fc`
  custom format compresses by default — pass `-Z0` if you want it.
- **MySQL/MariaDB:** plain `mysqldump` output is already text. Do not pipe it
  through `gzip`.
- **Let borg compress** — `compression: zstd` in borgmatic, or `--compression zstd`
  directly. borg has shipped zstd since 1.1.4, so 1.4.4 has it.

⚠ **borgmatic's streamed database hooks sidestep this entirely**, which is a
reason the trap matters less under the chosen tool than it would have under a
restic wrapper: there is no intermediate file to be tempted to compress. The
warning is kept because the temptation returns the moment anyone writes a
hand-rolled dump script alongside it.

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

The pattern is still worth mirroring **only if borgmatic's own hooks are not
used**: a systemd timer dumps into a directory, borg backs up that directory, and
the dumps carry their own small retention so the directory does not grow without
bound. Ordering matters — **the dump timer must complete before the borg run
starts**, or the backup captures yesterday's dump and reports success.

⚠ **borgmatic removes this whole class of problem**, which is the main reason it
won (§4). Its database hooks dump *during* the backup and stream the result
straight in, so there is no intermediate directory, no retention to manage on it,
and no ordering constraint to get wrong. Reach for the timer pattern only for a
database borgmatic cannot address natively.

⟨Feeds the `appdata` per-container pass (`hosts/galactica/SHARES.md` §3): each
container needs a verdict on which of the three approaches applies, and that is
the same pass that assigns its tier.⟩

## 5. ⚠ The key custody problem — design this before trusting anything

Self-managed encryption removes the vendor's ability to lose your key. It also
removes their ability to help you recover it. **The backup key becomes Critical
data that cannot be stored in the backup**, and the fleet's current trust chain
is circular:

```
borg repo  ←  borg passphrase  ←  sops  ←  admin age key  ←  ⟨a machine⟩
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

- **Size the Critical and Precious tiers** (§3) — against the 950 GB ceiling
  rather than to choose a mechanism, which is now settled.
- ~~**Choose an SSH-based provider.**~~ **Closed 2026-08-08 — BorgBase**, at a
  950 GB budget (§3). It exposes append-only as a per-key toggle, which was the
  differentiating property. Object storage, including iDrive e2 and B2, was
  already out once borg was chosen; Proton Drive was rejected earlier for
  offering no scoped credentials.
- **Create the repository in `repokey` mode**, not `keyfile` (§4) — it collapses
  key custody to one secret and is decided once, at creation.
- **Verify append-only actually works** on BorgBase (§3). This is the
  security-relevant one, and it is now a concrete test rather than a provider
  question: with Tower's append-only key in place, run `borgmatic prune` and
  confirm the *server* refuses. Also set up the second, prunable key on the admin
  machine, since retention cannot run from Tower.
- **Design key custody** (§5) *before* the first backup runs, not after.
- **Set the 2027-02 renewal reminder** (§4b) so the iDrive decision is made
  deliberately rather than by the date arriving.
- **Turn on BorgBase's own inactivity alerting** (§3), as a heartbeat that does
  not depend on hopper being up — the one gap a self-hosted watcher cannot cover.
- **Decide pegasus's target** (§4b) — borgmatic now, or iDrive until renewal.
- **Retention numbers for the hot and cold classes** (§4). The hot/cold split was
  taken on 2026-08-08 *because* the two want different policies; until the numbers
  differ, the split is cost without benefit. Critical requires versioning, so hot
  needs real depth; cold is near-immutable and needs far less.
- **Work out a dump path per database** (§4d) before the first backup runs. A
  file-level copy of a live database is the most common way a backup turns out
  worthless, and it is also the migration's prerequisite.
- ⭐ **Run the pilot** — `hosts/galactica/DESIGN.md` §6.6. Wire `partdb` for
  backup, then test-migrate and restore it onto memory-alpha. It proves this
  document's whole design end to end at a size where being wrong is free: the
  borgmatic config shape, the native database hook, BorgBase's append-only
  refusal, the tier → `source_directories` path, and the paired-appdata rule
  that `partdb` itself generated.

  **This is the item that turns the rest of §6 from a plan into evidence**, and
  it should run before the first real backup is trusted — a backup that has
  never been restored is a belief. ⚠ It proves nothing about SnapRAID, mergerfs
  or the migration's exposure window; those are galactica-specific.
- **Wire the three signals** (§3b) — Kuma push monitor for the heartbeat, ntfy
  for the budget thresholds, `RequiresMountsFor=` so an unmounted source cannot
  produce a green empty backup. Plus the quarterly restore-test nag.
- **Build the bind-mount reconciliation check** (§4c). The declared tier → path
  list is the *source*; this compares it against what the containers actually
  mount and shouts when they diverge.

  ```sh
  # Auditor, not source. Compare to the declared list; alert on either direction.
  docker ps -a --filter "label=backup.tier" -q \
  | xargs docker inspect --format \
    '{{range .Mounts}}{{if eq .Type "bind"}}{{.Source}}
  {{end}}{{end}}'
  ```

  ⚠ **Use `docker ps -a`, not `docker ps`.** The whole point is catching the
  container that is stopped, and the plain form hides exactly those.

  **Both directions matter, for different reasons.** A path mounted but not
  declared is an unprotected volume — the drift this check exists for. A path
  declared but no longer mounted is a *stale* entry, which is worse than it
  looks: borg happily backs up a directory that no longer receives writes, so
  the repo keeps growing and the heartbeat keeps passing while the real data
  moved somewhere unwatched. Neither direction is safe to ignore.

  Alert via ntfy (§3b), and treat a divergence as a **prompt to update the Nix
  declaration**, never as a reason to make the check derive paths at runtime —
  that would reintroduce the failure mode §4c rejects.
- ~~**Decide on physical rotation for Tower.**~~ **Closed 2026-08-07** — the
  950 GB cloud budget makes it unnecessary. Kept in §6 as the fallback if the
  Precious tier ever outgrows the budget by more than it is worth paying for.
- **Survey memory-alpha, hopper and hamilton.** They are blank in §2 because
  nobody has looked, not because they are known to have nothing.
