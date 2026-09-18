# serenity — offsite backup: Vorta, not borgmatic

⚠ **Decided 2026-08-15**, superseding the tool choice `docs/BACKUP.md` §4b had
been assuming for both desktops. Every other host now on offsite
(galactica, pegasus, memory-alpha — `docs/BACKUP.md` §2) runs borgmatic;
serenity is the one deliberately different, and the only one still
**pending setup** as of 2026-09-16.

## Why Vorta instead of borgmatic

Both are just clients for the same Borg repository format, so this doesn't
change what ends up on BorgBase — `serenity-home` is a plain repo, an
append-only key for the host, same key-custody shape as every other repo in
the fleet (`hosts/pegasus/borgmatic.nix`, `hosts/memory-alpha/borgmatic.nix`).
It changes *who schedules and runs* the backup:

- ⭐ **Vorta has native network restriction; borgmatic doesn't.** Checked
  directly against borgmatic's config schema — no network/Wi-Fi option
  anywhere in it, only bandwidth limits. Vorta's per-profile "Networks" tab
  is backed by real platform code (`network_status/darwin.py`, via macOS's
  CoreWLAN framework, not a stub): it can allow-list which Wi-Fi SSIDs a
  scheduled backup is permitted to run on, plus a separate "don't run on
  metered networks" toggle. Worth having on a Mac that isn't guaranteed to
  always be on the home network — borgmatic would need a hand-rolled
  `commands:` before-hook shelling out to `networksetup` to get the same
  thing, which Vorta already does natively.
- It's a GUI, which fits a machine a human sits at daily better than the
  unattended-daemon model the NixOS hosts use.

There is no `hosts/serenity/borgmatic.nix` and none is planned — running one
alongside Vorta against the same repo would mean two uncoordinated
schedulers hitting one lock, the exact conflict flagged when Vorta was first
evaluated for this fleet.

## Setup — needs a human at the Mac; nothing here does this automatically

1. [ ] Generate a dedicated ed25519 keypair — not galactica's, pegasus's,
       memory-alpha's, or z's own SSH key:
       ```sh
       ssh-keygen -t ed25519 -f serenity-vorta -N ""
       ```
2. [ ] Create the `serenity-home` repo on BorgBase (same account backing the
       other hosts' repos — see `docs/BACKUP.md` §3/§4 for provider and
       budget context if the account details aren't at hand). Register the
       public half of the key above as its **append-only** key.
3. [ ] `darwin-rebuild switch` to pull in the Vorta cask
       (`modules/darwin/homebrew.nix`), or `brew install --cask vorta`
       directly if you don't want to wait for a full switch.
4. [ ] In Vorta, add the repo (Add Existing Repository, or Initialize if
       BorgBase left it uninitialized for the client to set up — Vorta walks
       you through either case): the SSH URL for `serenity-home`,
       `repokey-blake2` encryption, a **new passphrase distinct from every
       other host's**, and the private key from step 1.
5. [ ] Add Source: `/Users/z`, excluding `~/Library` (this also covers Steam
       on macOS, which installs under `~/Library/Application Support/Steam`
       — no separate exclusion needed) and anything else noisy once archives
       start growing.
6. [ ] Networks tab: allow-list only the home Wi-Fi SSID, and enable "don't
       run on metered networks."
7. [ ] Archives tab: set a retention policy (`keep daily`/`weekly`/`monthly`)
       sized like the other hosts' `keep_daily`/`keep_weekly`/`keep_monthly`
       (`hosts/pegasus/borgmatic.nix`, `hosts/memory-alpha/borgmatic.nix`)
       unless serenity's churn calls for something different. This runs fine
       under the append-only key — prune only marks archives deleted in the
       manifest, it doesn't need server-side delete rights (verified on
       pegasus and galactica, `hosts/galactica/BACKUP-BORG.md`). Only
       *compaction* — reclaiming the freed disk space — needs a separate
       step: BorgBase's dashboard exposes "More > Compact repo" as a manual
       action that runs with its own authority, no key involved. Do that
       periodically once archives are piling up.
8. [ ] Schedule tab: pick an interval, but run the first backup by hand
       first and time it — same discipline as every other host in this
       fleet before trusting anything unattended.
9. [ ] Turn on BorgBase's own inactivity alerting for this repo in its UI
       (`docs/BACKUP.md` §3b) — that's the heartbeat signal every other
       host's repo already relies on instead of a per-backup ntfy hook.

## Still open

- Whether iDrive and the two rotated Time Machine drives stay in place
  alongside this. Nothing here retires them — that's a separate decision.
- The append-only refusal still needs verifying end to end for this repo
  specifically (`docs/BACKUP.md` §3: attempt a delete with the append-only
  key, confirm the *server* refuses) — a claim in a web UI isn't a fact
  until tested, same as every other host's repo.
