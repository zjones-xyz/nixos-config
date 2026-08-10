# Tower — borgmatic configuration

Offsite backup configs for the shares in Tower's offsite scope. **Drafts** —
nothing here has run yet, and several values are deliberately `REPLACE`.

Dates are UTC.

---

## Why YAML in a Nix repo

Because Tower is still on Unraid, and the backup is not waiting for the
migration. `docs/BACKUP.md` §4b's timeline has always read "**Now** (2026-08):
Tower → borgmatic → BorgBase" — it was never gated on NixOS.

**This costs almost nothing, and that is by design.** The 2026-08-08 decision to
make `/etc/borgmatic.d/<service>.yaml` the *unit of configuration* was taken for
service mobility. It pays off here for a reason that was not the point at the
time: the YAML is the portable artifact, and it is identical whether delivered by
a Docker container on Unraid today or by `services.borgmatic.configurations` on
NixOS later. Only the *delivery mechanism* changes.

Same shape as `BACKUP.md` §4c's conclusion about Compose labels — right tool for
the transition, and the transition is where we are.

## The files

| File | Sources | Repo | Why |
|---|---|---|---|
| `documents.yaml` | `documents` | `tower-hot` | 🔴 Critical. Small, high churn, deep versioned retention |
| `appdata.yaml` | `appdata` (whole share) + DB dumps | `tower-hot` | Paired-appdata rule; 76.1 GiB, so no per-service carve-out needed |
| `immich-photos.yaml` | `immich_photos`, `immich_photos_archived` | `tower-cold` | 💎 Precious. ~200 GiB, near-immutable, far fewer versions |

That is the whole offsite scope — three shares plus appdata, per
`SHARES.md` §5. Everything else in the inventory is **Protected or below: parity,
no offsite.** Keeping the top two tiers small is the entire point; every share
that moves out of them is one that stops costing money every month.

⚠ `partdb` is **not** here. It is Protected — no offsite — and the fact that
`DESIGN.md` §6.6 uses it for the pilot does not put it in scope. The pilot's
config is a rehearsal, written separately and thrown away.

## ⚠ Immich is split across both repos, and that is a constraint

The hot/cold boundary is *churn*, not service. Immich's Postgres is high-churn
(hot); its photos are near-immutable (cold). So a restore of Immich touches
**both repositories**, and the paired-appdata rule says they must come back
together.

> **Therefore: hot's retention must reach back at least as far as cold's.**

Otherwise there is a depth at which you recover photos with no database to give
them meaning. `appdata.yaml` is set to 24 monthly / 3 yearly against
`immich-photos.yaml`'s 12 / 3, so it holds with margin. **Do not shorten
appdata's retention without revisiting this.** ⟨Not currently stated in
`BACKUP.md` §6 — it falls out of the hot/cold split meeting the paired-appdata
rule, and neither document noticed.⟩

## Delivery on Unraid

Docker container, `/mnt/user` mounted at the same path inside so these configs
need no rewriting, plus the Docker socket so the database hooks can `docker exec`
(see below).

⚠ **Unraid's root filesystem is a RAM disk.** Anything outside `/boot` and the
shares is gone at reboot, so borgmatic's own state lives on a share:

```
/mnt/user/appdata/borgmatic/
├── passphrase            # 0600. See key custody below.
├── ssh/id_ed25519        # the BorgBase key — append-only
├── ssh/known_hosts
└── borg-cache/           # losing this is slow, not wrong: full re-read to
                          # rebuild the chunk index on the next run
```

⚠ That directory is **excluded** in `appdata.yaml`, because it sits inside the
share it backs up and otherwise the repository passphrase would be stored inside
the repository.

## ⭐ The database hooks do not need a shared Docker network

borgmatic 2.1.5's `postgresql_databases` and `mariadb_databases` take a
**`container:`** option — *"Container name/id to connect to. When specified the
hostname is ignored. Requires docker/podman CLI."* So mounting the Docker socket
is sufficient; the borgmatic container does not have to join every database's
network. `sqlite_databases` is different — it takes a `path:`, and the file just
has to be visible inside the container.

## ⚠ Two traps verified against the 2.1.5 schema, not recalled

**1. borgmatic's PostgreSQL defaults gzip the dump.** `format` defaults to
`custom` (not `plain`), and `compression` defaults to *"moderate gzip for custom
and directory formats"*. That is `BACKUP.md` §4d's pre-compression footgun
arriving through the front door — gzip output diverges globally from a one-row
delta, so borg's content-defined chunking stores a full copy every night instead
of the delta. §4d currently claims borgmatic "sidesteps this entirely"; it
sidesteps the *intermediate file*, not the compression. `appdata.yaml` pins
`format: plain` and `compression: none`. **mariadb is unaffected** — plain text,
no compression option.

**2. Any database hook silently enables `--read-special` tree-wide.** The schema:
*"when a database hook is used, the setting here is ignored and read_special is
considered true."* borg then tries to *read* every FIFO and socket it walks over,
and blocks. Containers scatter unix sockets through appdata routinely, so
`appdata.yaml` excludes `*.sock` / `*.socket` / `*.pid`. The symptom otherwise is
a backup that **hangs with no error**, which is a bad thing to be diagnosing
blind.

## What gates the first byte — less than `BACKUP.md` §6 implies

Only two things are genuinely irreversible-if-wrong:

- **`repokey` at repository creation.** Set in each file's `encryption:`. Changing
  it later means a new repository. `keyfile` mode splits custody in two; repokey
  collapses it to one secret, which is what §5's fireproof-box copy assumes.
- **Key custody (§5), designed before the first run.** The trust chain is
  circular — the passphrase is in sops, sops needs the admin age key, which lives
  on a machine. One copy must depend on no machine in the fleet. Paper in a
  fireproof box is the unglamorous answer that works.

**Retention numbers do NOT gate anything.** Tower's BorgBase key is append-only,
so prune *cannot* run from Tower by construction — it runs from the admin machine
with the second, prunable key, deliberately and rarely. The numbers in these
files are a proposal for whenever that first happens, weeks out.

`archive_name_format` only bites when a **second** config writes to the same repo
— which `documents.yaml` and `appdata.yaml` both do, so it matters here from day
one. ⚠ It is also `BACKUP.md`'s "single highest-consequence unverified
assumption", because its failure mode is silent deletion of another config's
history. **Test it in the pilot**: write from two configs into one repo, run
`prune --dry-run` on one, confirm the other's archives are not listed.

## Order of operations

1. **BorgBase account, two repos**, `tower-hot` and `tower-cold`. Append-only key
   for Tower; a second, prunable key that never touches Tower.
2. ⚠ **Verify append-only actually refuses.** Run `borgmatic prune` from Tower
   and confirm the *server* says no. A toggle in a web UI is a claim; this is the
   property the whole §3 design rests on, and the test is cheap.
3. **Key custody**, before anything is trusted.
4. **Run the pilot** (`DESIGN.md` §6.6) — `partdb` onto memory-alpha. It proves
   the config shape, the native database hook, the append-only refusal, the
   paired-appdata rule, and `archive_name_format`'s prune scoping, at a size
   where being wrong is free.
5. **Seed `tower-hot` first.** Small, so the Critical tier is genuinely protected
   within the hour.
6. **Then start `tower-cold` and leave it.** ~200 GiB is roughly half a day at
   ~40 Mbps up, a couple of days at ~10. It runs unattended — but **do not
   schedule a hardware window assuming it finished.** Check `borg info`.
7. **Wire the three signals** (`BACKUP.md` §3b): Kuma push monitors — *one per
   repo*, since a monitor nobody created is a gap nothing reports — ntfy for
   budget thresholds, and the canary files.

## ⚠ The canary is mandatory here, not optional

`BACKUP.md` §3b ranks `RequiresMountsFor=` first among guards against the
green-but-empty backup, and it is a systemd feature we do not have on Unraid.

`source_directories_must_exist: true` (set explicitly in all three files) covers
most of it — with shfs down, `/mnt/user/<share>` does not exist and borgmatic
errors rather than archiving nothing and firing the success hook. **It does not
cover mounted-but-empty**, so the canary file per source tree is the other half
and stops being optional. ⟨Not yet written.⟩

## Still `REPLACE`

- BorgBase repo URLs (both), and the SSH key.
- Uptime Kuma push URLs — one per repo.
- Immich's Postgres container name. `docker ps --format '{{.Names}}\t{{.Image}}'`.
- Every other database — the `mariadb_databases` and `sqlite_databases` stubs are
  commented out rather than guessed, because a hook naming a container that does
  not exist fails the run, and one naming the *wrong* container succeeds while
  backing up nothing you meant. They need the per-container `appdata` pass
  (`SHARES.md` §3), which has not run.

⚠ **Until that pass finishes, `appdata.yaml` copies undumped databases as
files.** They are in the archive and they are not restorable — which is worse
than absent, because it looks like protection.
