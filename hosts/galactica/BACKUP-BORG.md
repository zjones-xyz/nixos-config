# galactica — borgmatic offsite, ZFS-aware

How borgmatic selects ZFS datasets to back up, and how galactica is wired to use
it. Companion to `docs/BACKUP.md` (fleet policy: scope, budget, provider, key
custody) and `modules/nixos/borgmatic.nix` (the config this documents). Drafts —
nothing has run yet; the array does not exist and the BorgBase repo is not
created.

---

## The question: does borgmatic autoscan ZFS datasets, or is it per-dataset?

**Both mechanisms exist, and they are opt-in — borgmatic does not blindly sweep
every dataset on the pool.** Verified against the packaged borgmatic **2.1.5**
source (`borgmatic/hooks/data_source/zfs.py`, `config/schema.yaml`), not just the
docs. A dataset is snapshotted-and-backed-up if **either**:

1. **Property-driven (the autoscan path).** The dataset carries the ZFS *user
   property* **`org.torsion.borgmatic:backup`** with the **exact value `auto`**.
   borgmatic runs
   `zfs list -H -t filesystem -o name,mountpoint,canmount,org.torsion.borgmatic:backup`,
   and for every dataset where that value is `auto` it **injects the dataset's
   own mountpoint as a root backup pattern** — so the dataset is included **whether
   or not it appears in `source_directories`**. This is the "set it and forget
   it" autoscan: tag the dataset, and it is in scope forever.

2. **Path-driven.** A path in `source_directories` (or `patterns`) falls within a
   dataset's mountpoint. borgmatic walks parent directories to find the *closest*
   dataset containing each source path and snapshots that one. This is the "I
   listed `/tank/documents`, borgmatic figured out the dataset" path.

Datasets with **`canmount=off` are skipped** (a container dataset's snapshot
mounts empty, so backing it up would archive nothing). borgmatic **creates each
snapshot, mounts it read-only in its runtime directory, sends the frozen copy to
Borg, then destroys the snapshot** — the whole lifecycle is automatic, no
`zfs-auto-snapshot`/`sanoid` involved. Enabling the hook at all is a single
`zfs:` key in the config; **without that key borgmatic ignores ZFS entirely** and
just archives directories live.

So: **not an unconditional autoscan.** You either tag datasets with the property
(mechanism 1) or list their paths (mechanism 2). Nothing is backed up by
accident.

### Sources

- borgmatic — *Snapshot your filesystems*:
  <https://torsion.org/borgmatic/docs/how-to/snapshot-your-filesystems/>
- borgmatic — *ZFS* configuration reference:
  <https://torsion.org/borgmatic/reference/configuration/data-sources/zfs/>
- Primary source, this exact version — `borgmatic/hooks/data_source/zfs.py`
  (`BORGMATIC_USER_PROPERTY = 'org.torsion.borgmatic:backup'`; `== 'auto'`;
  `canmount != 'off'`) and `borgmatic/config/schema.yaml` (`zfs:` →
  `zfs_command`/`mount_command`/`umount_command`) in the packaged
  `borgmatic-2.1.5`.

---

## Recommendation for galactica: property-driven (mechanism 1)

`modules/nixos/borgmatic.nix` sets `source_directories = [ ]` and relies purely
on the property. **Why this over an explicit path list:**

- **The tier boundary lives on the pool, not in Nix.** The offsite boundary is
  exactly Critical + Precious (`hosts/galactica/SHARES.md` §5). Tagging those
  datasets puts the selection where the data and its tier already live, and it
  **survives dataset renames and remounts** — a path list in Nix does not.
- **The dataset names are not finalised.** `MANUAL-STEPS.md` §10 still has
  `tank/appdata` as "name TBD", and the array does not exist yet. A hardcoded
  mountpoint list would be guessing; a property is applied once, live, when the
  dataset is created with its final name.
- **One place to add scope later.** Bringing `tank/appdata` subtrees in becomes
  one `zfs set`, with no Nix change and no redeploy.

### The one-time tagging (owner, once the array exists)

```
zfs set org.torsion.borgmatic:backup=auto tank/documents           # 🔴 Critical
zfs set org.torsion.borgmatic:backup=auto tank/photos/immich        # 💎 Precious
zfs set org.torsion.borgmatic:backup=auto tank/photos/immich_archived  # 💎 Precious
# later, per SHARES.md §5, if appdata subtrees enter scope:
# zfs set org.torsion.borgmatic:backup=auto tank/appdata/<service>
```

(Dataset names above follow this task's `tank/photos/immich*` layout; if the
array is built with the flat `immich_photos` / `immich_photos_archived` names the
docs also use, tag those instead. The property does not care what the dataset is
named — that is the point.)

The property **inherits to children**, so tagging a parent pulls in every child
dataset. If a child should be excluded, set `=auto` on the parent and something
other than `auto` (e.g. `-`/unset via `zfs inherit`, or any non-`auto` value) on
the child — only the literal `auto` triggers inclusion.

### The catch: borgmatic keys off ITS property, not our `homelab:tier`

We would like one source of truth. We cannot quite have it: **borgmatic only reads
`org.torsion.borgmatic:backup`**, hardcoded — it will never read our semantic
`homelab:tier` property. So the two coexist:

- **`homelab:tier`** stays the semantic source of truth (critical / precious /
  protected / …), inherited down the tree, driving parity/snapshot policy.
- **`org.torsion.borgmatic:backup=auto`** is a thin *derived* marker, set only on
  the leaves where `homelab:tier ∈ {critical, precious}`.

The cleanest reconciliation is to treat the borgmatic property as **derived from
the tier**, and to add a drift check (a one-liner, not automation yet) to the
array bring-up: every dataset with `homelab:tier` of critical/precious should
have `org.torsion.borgmatic:backup=auto`, and nothing else should:

```
# datasets in the offsite tier that are NOT tagged for borgmatic (should be empty):
zfs get -H -o name,value homelab:tier tank -r \
  | awk '$2=="critical" || $2=="precious" {print $1}' \
  | while read ds; do \
      [ "$(zfs get -H -o value org.torsion.borgmatic:backup "$ds")" = auto ] \
        || echo "MISSING borgmatic tag: $ds"; \
    done
```

⟨Alternative considered and rejected for now: drop `source_directories`-less
selection and instead list `/tank/documents` etc. explicitly in the Nix config
(mechanism 2). It keeps everything in one file and is greppable, but it
re-encodes the tier boundary in Nix — a second place to keep in sync, that goes
stale on a rename, for datasets whose names are not even settled. Property-driven
wins here; revisit if the offsite set ever needs to differ from "whatever carries
the tier".⟩

---

## What the single uniform config defers: the hot/cold split

The old Unraid-era design (`docs/BACKUP.md`, and the `origin/borgmatic_backup`
draft) split the offsite scope into **hot** (documents + Immich's Postgres:
small, high-churn, deep retention) and **cold** (photos: large, near-immutable,
shallow retention) repos, because retention economics differ sharply between
them.

**borgmatic retention is per-config, not per-dataset.** Property-driven discovery
pulls every tagged dataset into *one* config with *one* retention policy, so this
module cannot express hot/cold on its own. That is a deliberate simplification
for the starting point:

- **Now:** one config, one uniform `keep_*` policy sized for the mixed set.
  Simple, property-driven, one marker per dataset.
- **If/when hot/cold matters:** split into two configs, each with an explicit,
  narrow `source_directories` (mechanism 2) — documents/DB → `galactica-hot`,
  photos → `galactica-cold` — accepting that the two explicit lists are the cost
  of per-tier retention. The paired-appdata rule then applies: **hot's retention
  must reach back at least as far as cold's**, or you recover photos with no
  database to give them meaning.

---

## Immich database — not wired yet, on purpose

The Precious photos are only meaningful with Immich's Postgres, which is
high-churn and needs a consistent dump (borgmatic's native `postgresql_databases`
hook, `container: immich_postgres`). It is **not** in `borgmatic.nix` yet because
Immich is not running on galactica (Docker is down through the migration). A DB
hook pointed at a non-existent container would fail every run. When Immich comes
up, add it — and mind the two footguns already verified in the fleet's notes:

- `format: plain` + `compression: none` on the Postgres hook, or borgmatic's
  default gzip defeats Borg's dedup (`docs/BACKUP.md` §4d's pre-compression
  footgun, arriving through the front door).
- Any database hook silently forces `read_special` tree-wide, so borg blocks on
  container sockets unless `*.sock`/`*.socket` are excluded.

---

## Runtime footguns in the systemd unit (the load-bearing overrides)

The packaged `borgmatic.service` (2.1.5) is hardened in ways that **break the ZFS
hook** until overridden. `modules/nixos/borgmatic.nix` sets all three; they are
verified against the unit file and its own inline comments:

1. **`LoadCredentialEncrypted=borgmatic.pw`** — the unit's default
   systemd-creds/TPM secret path. This fleet uses sops; systemd refuses to start
   a unit whose credential target is missing. Overridden to a single empty-string
   element (which renders the `LoadCredentialEncrypted=` reset line). Same fix as
   `hosts/pegasus/borgmatic.nix`.
2. **`PrivateDevices=yes`** hides `/dev/zfs` — the unit's own comment: "Filesystem
   hooks like ZFS and LVM may not work unless PrivateDevices is disabled." Set to
   `false`.
3. **`CapabilityBoundingSet` lacks `CAP_SYS_ADMIN`** — it ships as
   `CAP_DAC_READ_SEARCH CAP_NET_RAW`, but `zfs snapshot` *and* mounting the
   snapshot both need `CAP_SYS_ADMIN` (the unit comment literally suggests adding
   it). Added.

⚠ **Still needs a real run to confirm** the snapshot actually mounts under
`ProtectSystem=full` + `RestrictNamespaces=yes`. Those should be fine — the mount
lands in the unit's writable `/run/borgmatic`, `@mount` is in the unit's
`SystemCallFilter`, and the zfs kernel module is preloaded at boot
(`boot.supportedFilesystems`, `boot.zfs.extraPools`) so `ProtectKernelModules=yes`
never has to load it on demand — but this is the one thing that can only be
proven live. First scheduled run against a tagged dataset settles it.

---

## What the owner must create (nothing here invents secret values)

> **✅ LIVE as of 2026-09-03.** First backup ran clean: ~208 G of source
> (tank/documents + tank/photos/*) → 104.6 G uploaded after dedup+zstd (~21% of
> the repo's 500 G quota), 1h53m wall, archive consistency check passed. The ZFS
> snapshot hook fired correctly under the hardened systemd unit (the one
> live-only unknown). Repo `kentmevx` on BorgBase, `repokey-blake2`, galactica's
> key back to **append-only** after init. The old ntfy hook was dropped (item 8
> is moot) in favour of BorgBase inactivity alerting. Module + this doc landed on
> the galactica branch; PR #90 superseded.

1. [x] **BorgBase account + one repo.** Created; `repokey-blake2`. Repo URL
       `ssh://kentmevx@kentmevx.repo.borgbase.com/./repo`.
2. [~] **Two keys:** the **append-only** key for galactica is created, verified
       against BorgBase, and materialised via sops. The repo was initialised by
       *temporarily* toggling that same key to full-access, running
       `borgmatic repo-create`, then toggling it back to append-only (no second
       key needed for init). ⏳ Still TODO: a **separate prunable key** kept off
       galactica (admin machine) for retention runs — not needed until the first
       prune. Verify it actually refuses a `prune` from galactica before trusting.
3. [x] **Set the repo URL** — `homelab.borgmatic.repository`, set in
       hosts/galactica/configuration.nix.
4. [x] **Two sops secrets** (`borgmatic/passphrase`, `borgmatic/ssh_key`) in
       `secrets/galactica.yaml`. ⏳ Insurance still TODO: passphrase on paper for
       the fireproof box + `borgmatic borg key export --paper` (repokey ⇒ the key
       lives in the repo; an offline copy is the recovery path — docs/BACKUP.md §5).
5. [x] **`known_hosts`** pinned at `/var/lib/borgmatic/ssh/known_hosts`.
6. [x] **Tag the datasets** — `org.torsion.borgmatic:backup=auto` on
       `tank/documents` (critical) + `tank/photos` (precious; inherits to
       immich/immich_archived). Protected/other tiers deliberately excluded.
7. [ ] **Turn on BorgBase inactivity alerting** for the repo (`docs/BACKUP.md`
       §3, §3b) — the heartbeat that catches a silently-stopped backup.
8. [x] ~~ntfy token if locked down~~ — moot: the ntfy hook was removed from the
       module (BorgBase inactivity alerting covers this, per pegasus's precedent).

Still open beyond the checklist: the **Immich Postgres dump hook** (§ above) — the
current backup is photo *files*, not a one-click full Immich restore — and the
hot/cold retention split, both deliberately deferred.
