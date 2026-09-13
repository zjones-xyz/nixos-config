# serenity — offsite backup: Vorta, not borgmatic

⚠ **Decided 2026-08-15**, superseding the tool choice `docs/BACKUP.md` §4b
had been assuming for both desktops. Pegasus still uses borgmatic
(`hosts/pegasus/borgmatic.nix`) — this page is serenity only.

## Why Vorta instead of borgmatic

Both are just clients for the same Borg repository format, so this doesn't
change what's on BorgBase — `serenity-home` is still a plain repo, an
append-only key for the host, a separate prunable key kept off it entirely,
same key-custody shape as every other repo in the fleet. It changes *who
schedules and runs* the backup:

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
  unattended-daemon model Tower and pegasus use.

`hosts/serenity/borgmatic.nix` — the earlier draft that ran borgmatic
directly from a launchd daemon — has been removed rather than left disabled.
Running it alongside Vorta against the same repo would mean two
uncoordinated schedulers hitting one lock, which is the exact conflict
flagged when Vorta was first evaluated for this fleet.

## Setup — needs a human; nothing here does this automatically

1. Generate a dedicated ed25519 keypair — not Tower's, not pegasus's, not
   z's own SSH key:
   ```sh
   ssh-keygen -t ed25519 -f serenity-borgbase -N ""
   ```
2. Create the `serenity-home` repo on BorgBase (same account as Tower's and
   pegasus's — see `hosts/galactica/borgmatic/README.md` if it doesn't exist
   yet). Register the public half of the key above as its **append-only**
   key. Set up a second, prunable key on the admin machine — never on
   serenity itself.
3. `darwin-rebuild switch` to pull in the Vorta cask
   (`modules/darwin/homebrew.nix`), or `brew install --cask vorta` directly
   if you don't want to wait for a full switch.
4. In Vorta, add the repo (Add Existing Repository, or Initialize if
   BorgBase left it uninitialized for the client to set up — Vorta walks you
   through either case): the SSH URL for `serenity-home`, `repokey-blake2`
   encryption, a **new passphrase distinct from every other host's**, and
   the private key from step 1.
5. Add Source: `/Users/z`, excluding `~/Library` (this also covers Steam on
   macOS, which installs under `~/Library/Application Support/Steam` — no
   separate exclusion needed) and anything else noisy once archives start
   growing.
6. Networks tab: allow-list only the home Wi-Fi SSID, and enable "don't run
   on metered networks."
7. Schedule tab: pick an interval, but run the first backup by hand first
   and time it — same discipline as every other host in this fleet before
   trusting anything unattended.
8. Notifications, if wanted: Vorta can run a command after each backup;
   point it at the same `ntfy.hopper.internal` pattern the other hosts use
   (topic `serenity-backup`, matching `docs/BACKUP.md` §3b).

## Still open

- Whether iDrive and the two rotated Time Machine drives stay in place
  alongside this. Nothing here retires them — that's a separate decision.
- The append-only refusal still needs verifying end to end (`docs/BACKUP.md`
  §3: attempt a delete with the append-only key, confirm the *server*
  refuses) — a claim in a web UI isn't a fact until tested, same as Tower's.
