# galactica — manual steps (gated on being physically at Tower, or on the ISO)

`configuration.nix`, `disko.nix`, and `home.nix` exist now, but
`nixosConfigurations.galactica` is deliberately not yet in `flake.nix` —
`hardware-configuration.nix` doesn't exist and can't be evaluated blind. See
the header comment in `configuration.nix` for why. Everything below closes
that gap, roughly in order.

An opus review agent independently checked this whole plan on 2026-08-31 —
several fixes below exist because of it, credited inline where they matter.

## 1. ✅ Device identities — confirmed 2026-08-31, run directly on Unraid

All three resolved (Unraid is Linux too — no need to wait for the ISO for
read-only discovery like this):

| What | Confirmed value |
|---|---|
| NVMe root | `nvme-SPCC_M.2_PCIe_SSD_AA2300905N401KG00206` |
| midden (formerly Unraid's `fastservices` pool) | `ata-SATA_SSD_19013024009545` |
| Onboard NIC driver | `e1000e` |

Both `disko.nix` and `configuration.nix` already have these baked in. Still
worth a last-look `ls -l /dev/disk/by-id/` right before actually running
disko, on the ISO with both HBA cables disconnected (sidepool on one, the
three SATA SSD pools on the other) — belt-and-suspenders against anything
having shifted, since disko wipes whatever `device` points at.

## 2. Run disko, then generate real hardware-configuration.nix

Boot `galactica-live-iso` (rebuild it first — it now carries `disko` and
`git`, added specifically to drive this step rather than just diagnose
hardware):
```bash
nix build .#nixosConfigurations.galactica-live-iso.config.system.build.isoImage
```
Get the repo onto the booted ISO. Simplest: from pegasus or serenity, which
already have both the repo and standing SSH access to the ISO's root
account (`live-iso.nix`'s `authorizedKeys`) — no need for the ISO itself to
have outbound GitHub credentials, or to know/care whether the repo is
public:
```bash
rsync -a -e "ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null" ~/nixos-config/ root@<tower-ip>:~/nixos-config/
```
`StrictHostKeyChecking=no`/`UserKnownHostsFile=/dev/null` since the ISO gets
a fresh SSH host key every boot (tmpfs root) — nothing worth remembering in
your real `known_hosts`. Then, on the booted ISO:
```bash
cd nixos-config
chown -R root:root ~/nixos-config
disko --mode disko ./hosts/galactica/disko.nix
nixos-generate-config --no-filesystems --root /mnt
```
`chown` because `rsync -a` as root preserves the *source's* ownership
(pegasus/serenity's `z` user, UID 1000) rather than defaulting to root —
without this, `nixos-install`'s flake fetcher refuses to trust the repo
later (libgit2's ownership check, same protection `git` itself added a few
years back). Cheapest to just do it every time you re-sync, rather than
find out again at install time.

⚠ **On this board, the NVMe will very likely not show up as a UEFI boot
target at all** — discovered live during this install, not a hypothetical.
`PLATFORM.md` §11 had flagged this as genuinely open; it's now answered,
negatively. If `disko --mode disko` above puts the ESP on the NVMe as
written, expect to redo it: see §2b below for the live fix that was
actually applied, and consider just starting there instead of installing
onto the NVMe's ESP first and discovering the problem after the fact.

## 2b. What actually happened this time — ESP moved to midden

After `nixos-install` completed once (onto the NVMe's ESP), the BIOS boot
menu's UEFI filesystem browser only ever listed the USB installer stick —
never the NVMe, across multiple attempts. Fix applied live: carved a new 1G
ESP out of `midden`'s `nixBuildScratch` allocation (shrunk from `"100%"` to
`"-1G"`, still empty at the time so a reformat cost nothing), reopened the
existing LUKS containers and remounted everything under `/mnt` **without**
the NVMe's ESP this time, then re-ran `nixos-install` against the corrected
layout. `disko.nix` and `hardware-configuration.nix` now reflect this as
the real, current state — the NVMe's original ESP partition is still
physically there but unused (vestigial, see disko.nix's warning comment).

**This is deliberately temporary.** `midden` is the one disk in this whole
design explicitly expected to fail within about a year (§10's reasoning,
originally about the Kingston, carried over when the plan moved to
`fastservices`/`midden` instead) — tying the machine's ability to boot at
all to that disk is worse than what its failure was supposed to cost. See
§9 for the plan to migrate this onto MX100 once the special-vdev disks are
reconnected.

Copy the generated `hardware-configuration.nix` into
`hosts/galactica/hardware-configuration.nix`, reconciling `fileSystems.*`
against what disko already declared (same reconciliation pegasus's disko.nix
comment describes) — **and don't stop at a clean diff**, three things the
generator will NOT reproduce on its own, all caught by the opus review:

- **`allowDiscards` on root.** `nixos-generate-config` emits
  `boot.initrd.luks.devices."cryptroot".device` but never carries over
  disko's `settings.allowDiscards = true`. Add it by hand — pegasus's own
  `hardware-configuration.nix` already does exactly this, with a comment
  explaining why; copy that pattern.
- **Swap won't come back as encrypted, or possibly at all.** disko's
  `randomEncryption = true` swap partition has no persistent on-disk
  signature (the signature lives on the ephemeral `/dev/mapper` device that
  exists only after each boot's fresh random key), so the generator can't
  detect or reproduce it. Hand-add:
  ```nix
  swapDevices = [ { device = "/dev/disk/by-partlabel/disk-main-swap"; randomEncryption.enable = true; } ];
  ```
  Skip this and the 32G partition just sits unused.
- **`allowDiscards` on the four special-vdev member disks**, once those are
  set up (see §7) — the overprovisioning/endurance plan for those depends on
  discards actually reaching the physical disks, same mechanism as root.

## 3. Wire the flake up — the mechanical last step

Once `hardware-configuration.nix` is real:

- Add `galactica` to `nixosConfigurations` in `flake.nix`, matching
  `memory-alpha`'s shape (no extra inputs needed — it's a plain x86_64-linux
  host like memory-alpha/pegasus).
- Add the `galactica` age key staging to `.sops.yaml`: `*admin` only for now
  (this host builds its own closure, so it doesn't need `*memory-alpha` the
  way hopper/hamilton do — DECISIONS.md §4). After first boot:
  ```bash
  ssh-to-age < /etc/ssh/ssh_host_ed25519_key.pub
  ```
  paste as `&galactica` in `.sops.yaml`, add it to the `secrets/galactica\.yaml$`
  rule, then `sops updatekeys secrets/galactica.yaml`.
- Generate the initrd SSH host key (unencrypted, outside LUKS — same as
  memory-alpha/pegasus):
  ```bash
  ssh-keygen -t ed25519 -N "" -f /etc/secrets/initrd/ssh_host_ed25519_key
  ```

`nix flake check` should be clean at this point — validate before the first
`nixos-rebuild switch`. (It was NOT clean as of 2026-08-31 even before this
step — see the crypttab fix already applied to configuration.nix, caught by
the opus review before it could bite here.)

## 4. midden's logs keyfile

Only `cryptlogs` needs this now — `/var/cache/nix-build` is unencrypted
(reversed 2026-08-31, see disko.nix's `nixBuildScratch` comment for why).
Once `disko.nix` has run and the LUKS partition exists:

```bash
head -c 4096 /dev/urandom > midden-keyfile
cryptsetup luksAddKey /dev/disk/by-id/<midden-logs-partition> midden-keyfile
blkid /dev/disk/by-id/<midden-logs-partition>      # get cryptlogs' UUID
```

Put the UUID into `configuration.nix`'s `environment.etc."crypttab"` entry
(replacing `CONFIRM_ME_LIVE_LOGS`), then `sops secrets/galactica.yaml` and
add `midden-keyfile`'s contents as `luks/middenKeyFile`.

## 5. ✅ journald's retention cap — decided 2026-08-31

`SystemMaxUse=32G` / `MaxRetentionSec=180day`, via `lib.mkAfter` in
`configuration.nix` so it extends rather than replaces `common.nix`'s
fleet-wide default. Leaves headroom on the 48G partition; retention is
generous now that space isn't the binding constraint.

Still worth knowing, not yet acted on: journald's default
`RateLimitBurst=10000` per 30s will start dropping messages from chatty
containers once the *arr stack is running, independent of the size cap.

## 6. Tower's UPS

`nut-scanner -U` on the real machine to get the real driver/port. The
commented-out `power.ups` block in `configuration.nix` needs fixing before
uncommenting, not just filling in — `modules/nixos/nut-client.nix` is
**already live on memory-alpha** and hardcodes its expectations: it monitors
`ups@tower.internal` (not `tower@tower.internal`) authenticating as
`monuser` (not `upsmon`). Rename the server-side UPS to `ups` and the
monitor user to `monuser` to match, or the client will simply fail to
connect. Also open the NUT protocol port, which nothing currently does:
```nix
networking.firewall.allowedTCPPorts = [ 3493 ];
```
Create `secrets/galactica.yaml`'s `nut/upsmonPassword` at the same time
(`sops secrets/galactica.yaml`), matching whatever password gets set for
`monuser` — this is shared with memory-alpha's own `nut/upsmonPassword` in
`secrets/memory-alpha.yaml`, which must hold the identical value.

## 7. Beszel agent

No config exists for this yet — `modules/nixos/beszel.nix` turned out to be
hopper's own hub+agent bundle, not a reusable agent module (see the comment in
`configuration.nix`, confirmed by the opus review reading the file directly).
Write a small host-specific unit: the `henrygd/beszel-agent` container, host
network mode, `KEY` env pointed at hopper's hub. Register galactica as a new
system in hopper's hub UI first to get that key.

## 8. memory-alpha's NFS mounts — the cutover (planned 2026-08-31, written 2026-09-05)

`hosts/memory-alpha/configuration.nix` mounts `tower.internal:/mnt/user/jellyfin`
and `tower.internal:/mnt/user/arr_managed_data` over NFSv4, and `README.md`
confirms `tower.internal` keeps resolving to this box. The mounts are `soft`
+ `x-systemd.automount` + `noauto`, so memory-alpha degrades rather than
hangs when Unraid goes away — but Jellyfin's library and the *arr stack's
managed data stay empty until galactica exports the equivalent paths again.

**Now written**, in `hosts/galactica/configuration.nix` (exports) and
`hosts/memory-alpha/configuration.nix` (mounts). What the plan above could not
decide — the pool name and dataset paths — is decided; what it recorded as an
open question is still open, and that shaped the result.

### What is exported, and what is not

| fsid | Path | Consumer |
|---|---|---|
| 104 | `/tank/nixflix_media/media` | memory-alpha `/mnt/media` — the *arr library galactica now manages |
| 101 | `/tank/media_staging/jellyfin` | memory-alpha `/mnt/unmanaged` — the hand-curated library the *arrs don't touch |
| 103 | `/tank/bambuddy_library` | unconfirmed; LAN-wide, which is why §8 chose LAN scope |
| ~~100~~ | `arr_media` | **not exported** — reserved |
| ~~102~~ | `arr_managed_data` | **not exported** — reserved |

**Why two are held back.** Preserving an `fsid` means never reusing the number
for different content, so an unexported one stays reserved rather than
recycled. `arr_media` has no dataset of that name after the migration, and
SHARES.md §3's open question — which of `arr_media`/`arr_managed_data` was the
library and which the downloads — was never answered; pointing 100 at a guess
is how a client silently gets the wrong tree. `arr_managed_data` still exists
as `tank/media_staging/arr_managed_data`, but its only known consumer was
memory-alpha's *arr stack, and that stack runs on galactica now.

**The new library takes a new fsid (104), not 100.** Same reasoning: 100's
content is unconfirmed, so it is not free to take.

**memory-alpha's `/mnt/arr_managed_data` is removed, not re-pointed** — it
existed to serve the *arr stack that has moved. Its data is still on the array
if it turns out to matter.

### Doing the cutover

1. [ ] **galactica first.** The mounts are `access denied` until the exports
   exist:
   ```bash
   sudo nixos-rebuild switch --flake .#galactica
   sudo exportfs -v          # expect the three paths above, with their fsids
   ```
2. [ ] **Then memory-alpha:**
   ```bash
   sudo nixos-rebuild switch --flake .#memory-alpha
   ls /mnt/media /mnt/unmanaged    # automount triggers on access
   findmnt -t nfs4
   ```
3. [ ] **Point Jellyfin at the new paths.** Its libraries are configured in its
   own UI, not in Nix — the old ones reference the dead
   `tower.internal:/mnt/user/…` mounts. `/mnt/media` is the path
   `modules/nixos/jellyfin.nix` already documents.
4. [ ] **Expect `/mnt/media` to be thin until the staged media is imported.**
   The *arr library fills from `tank/media_staging` when the media-stack run
   book's import step runs; that step arrives with the *arr stack, separately
   from this cutover. A sparse library here is that import pending, not a
   broken mount — check `/mnt/unmanaged`, which has content today, to tell the
   two apart.

⚠ `x-systemd.automount` is restored on both mounts, having been dropped while
the exports did not exist: with it, a consumer touching the mountpoint during a
switch fires a synchronous mount, and a failing mount lands the `.mount` unit
in `failed`, which makes `nixos-rebuild switch` exit non-zero. `soft` and
`nofail` stay for the case galactica is simply down — degrade, don't hang,
don't fail the switch.

⚠ Scope is `192.168.8.0/24` and mode is `rw`, both transcribed from the
decision above rather than re-decided. The *arr library is arguably a candidate
for `ro` now that galactica owns every write to it — Jellyfin only needs write
there if you turn on saving NFO/artwork beside the media. That is a change of
decision; make it deliberately or not at all.

## 9. The array itself

### ✅ Built and cold-boot-verified — 2026-09-01

The array now exists, and its config is declared and proven across a cold boot:

- **Pool `tank`** — RAIDZ1 over the four 12 TB spinners + a **3-way mirror**
  special vdev over the three healthy SSDs (WD Blue + both BX500s), all
  **LUKS-under-ZFS** (`ashift=12` forced — these are 512e drives; one sops
  `luks/arrayKeyFile` in slot 0 + a fleet recovery passphrase in slot 1 per
  disk). The MX100 hard-failed on its first write and was dropped (project
  memory `project-galactica-mx100-failed-3way-pivot`), which is why the
  special vdev is 3-way, not the planned 2×2 — a forward path to 2×2 exists
  (`zpool detach` + `add`) if a 4th SSD arrives.
- **Config** — crypttab (7 members, `nofail`, `discard` on the SSDs only),
  `zfs-import-tank` ordered `after cryptsetup.target`, `devNodes=/dev/mapper`,
  `extraPools=["tank"]`. Committed and **cold-boot verified**: the array
  auto-unlocks and imports from a power-cycle. `tank` ≈ 31.6 TiB usable.
- **`tank/appdata`** created, forced onto the special vdev
  (`special_small_blocks == recordsize == 64K`).
- **✅ ESP migrated off midden onto the WD Blue.** The WD Blue (+ both BX500s)
  were on the **LSI HBA** (PCI `02:00.0`), which this BIOS can't UEFI-boot
  (nor the NVMe — firmware pruned explicit NVRAM entries for both at POST).
  Fix: the WD Blue was physically **recabled from the LSI to onboard C204 port
  `ata1`**, after which it boots. `/boot` is now `0B82-159C` (WD Blue).
  Config: `canTouchEfiVariables = false` (this BIOS boots only the
  `\EFI\BOOT\BOOTX64.EFI` fallback, so the NVRAM entry "galactica-wdblue" is
  hand-owned); midden's ESP kept as a bootable fallback. See
  `hardware-configuration.nix`'s `/boot` header for the manual re-create
  command if NVRAM is ever cleared.

**Since done (2026-09-02):** the **dataset tree** — ~30 datasets organized by
content with backup tier as an inherited `homelab:tier` user property (not
tier-based paths; see the media-stack project memory), `tank/appdata` on the
special vdev, `tank/sort/*` as staging. And the **copy-back**: sidepool
reconnected on the LSI, mounted read-only, all 24 shares rsync'd in (~21 h,
every share rc=0), crown jewels (documents/photos/appdata) checksum-verified
against the source, plus the Unraid flash+config insurance into
`tank/backups/unraid`.

**Still to do:**

1. [x] Sweep the media datasets into `tank/media_staging/*` (zfs renames) so
   the media stack gets a clean library root; collections re-enter via *arr
   imports. (Said "nixarr" when written — the stack chosen since is nixflix,
   and the library root landed on `/tank/nixflix_media/media`; see §12.)
   ✅ 2026-09-02 — all seven (8.94 T) staged; `tank/media`/`tank/books` empty.
2. [x] Retire sidepool *logically*: unmounted + all four LUKS mappers closed
   2026-09-02 — disks are inert (LUKS-closed, nothing references them).
3. [ ] Pull sidepool's drives during the next in-case session (deliberately
   deferred with other case cleanup: the dead MX100 wants pulling too, the
   WD Blue's cable label is stale post-recable, and HARDWARE-MAP §3/§7's
   cage/port enumeration needs eyes-in-the-case anyway). Disks return to
   the drawer after a cooling-off period.
   > **2026-09-03 — data-safety precondition met; the pull leaves nothing
   > behind.** sidepool was reopened one last time (read-only: `cryptsetup
   > open --readonly` ×4 + `mount -o ro,rescue=nologreplay`) and its `pools/`
   > directory — 117 GB, the Unraid `cache`/`fastservices`/`services` pool
   > appdata plus `unraid_config` and `unraid_flash.img`, none of which were
   > array shares in the copy-back — was rsynced to
   > `tank/backups/sidepool-pools` and `--checksum`-verified byte-identical
   > (silent verify pass). `move_aside/` was confirmed to be only the already
   > migrated array shares. So only the physical case work remains; nothing on
   > sidepool is still needed. Mappers closed again afterward.
4. [ ] **NFS re-exports** — written; §8 carries the export table, the two
   fsids held back and why, and the switch-galactica-first sequence.

The original forward-looking notes below are now mostly satisfied; kept for
provenance.

---

Not part of this install at all — built afterward, per the migration
handoff's step 8, once `sidepool`'s cables are reconnected and its contents
reconfirmed readable. Its ZFS datasets and mountpoints land in a follow-up
commit to `configuration.nix` once the pool exists and dataset names are
settled, same "no config for a layout that doesn't exist yet" reasoning
`DECISIONS.md` §3 already applied to the whole host before this file existed.

Three things the opus review flagged to remember when writing that config,
forward-looking rather than blocking now:

- `zfs-import-<pool>.service` has no ordering against `cryptsetup.target` by
  default — add `systemd.services."zfs-import-<pool>".after =
  ["cryptsetup.target"];` so import doesn't race the four LUKS opens on
  first boot after a cold start.
- Prefer `boot.zfs.pools.<name>.devNodes = "/dev/mapper";` explicitly rather
  than relying on the `/dev/disk/by-id` default — dm-crypt mappings do
  appear there, but the mapper path is the less ambiguous one to import by.
- `boot.zfs.extraPools` will be needed if any dataset uses a ZFS-native
  mountpoint rather than a `fileSystems.*` entry — nothing else triggers the
  import at boot in that case.
- **`appdata` as a ZFS dataset, forced onto the special vdev** (decided
  2026-08-31, reversing the migration handoff's original "NVMe: appdata,
  Docker volumes, swap" plan — see §10). Create `tank/appdata` (name TBD)
  with `special_small_blocks` set at or above its `recordsize`, so every
  block lands on the special vdev's mirrored SSDs rather than the RAIDZ1
  spinners — real redundancy for the host's most irreplaceable mutable
  state, which a single unmirrored NVMe subvolume never gave it. Needs its
  own snapshot policy via native `zfs snapshot`/`zfs destroy` (a timer, or
  sanoid), not `btrbk` — `DECISIONS.md` §7 already flagged needing "a
  snapshot mechanism that is not btrbk" for the photo tier; same need, one
  dataset earlier. Consequence, accepted knowingly: Docker/appdata-dependent
  services can't start until the array — special vdev included — is fully
  built. No interim NVMe home, on purpose.
- **Future, explicitly deferred — an NVMe acceleration/hot tier for `tank`
  (discussed 2026-09-02).** The idea: use the root NVMe (much faster than the
  SATA special-vdev SSDs) as a tier above them. Conclusions:
  - ZFS has **no automatic heat-based tiering** — the special vdev is the only
    automatic placement and it is *size*-based (`special_small_blocks`), not
    access-frequency-based. So a self-promoting hot-NVMe layer isn't a native
    option (would need bcache/dm-cache under ZFS — not worth it).
  - **L2ARC** (`zpool add tank cache <nvme-part>`) is the closest — a
    redundancy-neutral read cache above everything. Judged **marginal for this
    workload**: metadata + all of `appdata` already live on the special vdev,
    media reads are sequential (L2ARC skips those), and 32 GB ARC already
    covers most of the random-read window. Also needs a partition carved from
    the root NVMe (currently `cryptroot`+swap, no free partition). Low-risk to
    try later (removable) but **measure hit rate before committing space**.
  - **SLOG** helps only sync writes — negligible here. Skip.
  - **Direct placement is the real path** (and the same idea as the bullet
    below): promote specific latency-bound databases *onto* the NVMe (a small
    second pool/dataset), trading ZFS redundancy for backups. Per-service,
    measured, once real workloads exist — not a pool-wide tier.
- **Future, explicitly deferred:** individual databases may later get
  "promoted" back onto the NVMe for latency, relying on backups rather than
  ZFS redundancy for those specific ones. Not designed yet — a per-service
  decision for whoever's doing the appdata tiering once real workloads
  exist to measure.
- **⚠ Degraded-disk contingency (RAIDZ1 = 1-disk tolerance), 2026-09-02.**
  If a 12 TB member fails, the pool stays online + readable degraded; the only
  danger is a *second* failure before resilver. A replacement must be ≥ 12 TB
  (no smaller disk, no drawer spare qualifies, no raidz-shrink), and **recert
  12 TB enterprise drives are ~$350 (2026-09)** — a real cost, so a cold spare
  is **budgeted-when-affordable, not on hand**. Interim plan for a degraded
  window:
  - The offsite borg backup (`precious`+`critical`) survives even a double
    failure, and the `reacquirable` media is re-downloadable — so a degraded
    window risks a *painful media re-download*, not irreplaceable loss.
  - **Keep sidepool's disks as the zero-cost hedge.** When sidepool is retired
    (migration step 6), consider NOT reclaiming its 4 disks: hold them
    (old/partly-SMR — fine for temporary use) as an emergency `zfs send`
    target for the non-offsite `reacquirable` datasets if `tank` ever goes
    degraded. **This is a decision to make AT retirement time**, not purely
    deferred — flagged here so the retirement step weighs it.
  - **Do NOT concat those small disks into a fake 12 TB member.** Considered
    (`mdadm --level=linear` / LVM / RAID0 → `zpool replace tank <failed>
    /dev/md0`) and rejected: a no-redundancy concat makes the logical member
    die the instant *any one* of its 3–4 disks dies — **3–4× the failure
    probability, on the member you least want fragile**, which in a degraded
    pool is what takes the whole pool down. Resilvering onto SMR drives is
    days-to-weeks of punishment while they're your only parity margin, and
    LUKS → md/LVM → ZFS layering adds boot-assembly fragility (and 3 × 3.6 TB
    = 10.9 < 12, so it needs all four disks anyway). It restores vdev parity
    only on a foundation likely to re-degrade you. **Same disks, as the
    `zfs send` copy target above, have the opposite risk profile** — a
    small-disk failure costs part of a recoverable copy, not the pool. Use
    them as a copy, never as a member.
  - Weekly scrub + SMART (both on) to catch a second disk degrading early.
- **Migrate `/boot`'s ESP from `midden` to MX100** (see §2b — this is not
  optional cleanup, `midden` is expected to fail within about a year and
  currently hosts the only way this machine boots at all). Once the four
  special-vdev disks are reconnected:
  1. Identify MX100's by-id path (largest of the four, ~477GiB raw).
  2. Partition **around** any special-vdev allocation already planned for
     it — do NOT `blkdiscard` the whole disk. A 1G ESP plus its eventual
     420G special-vdev partition both fit with room to spare; the
     overprovisioning math barely moves (~56GB reserved instead of ~57GB).
  3. `mkfs.vfat`, copy the bootloader over (`bootctl install` from a
     booted system, or another `nixos-install` pass with `/boot`
     re-pointed), verify it actually boots from MX100 before touching
     `midden`'s copy.
  4. Update `fileSystems."/boot"` in `hardware-configuration.nix` to the
     new device, remove the ESP partition from `disko.nix`'s `disk.midden`
     (or leave it vestigial, matching how the NVMe's original ESP was
     handled — don't blindly wipe it without checking nothing still
     references it first).

## 10. `@appdata` — moved off the NVMe entirely (see §9)

Originally landed here as a plain btrfs subvolume, which turned out to have
a real gap: `modules/nixos/btrfs-snapshots.nix` only snapshots `@` and
`@home` (subvolumes are snapshot boundaries), so it had zero snapshot
coverage on the one subvolume most likely to hold irreplaceable state.
Rather than patch that gap in place, the whole subvolume was dropped from
`disko.nix` — `appdata` now belongs on the array's special vdev instead,
which gets it real mirrored redundancy AND a natural place for ZFS-native
snapshots, solving both problems at once rather than bolting `btrbk`
coverage onto a single-disk subvolume. See §9 for the actual plan.
Not fixed yet; needs a decision on the right mechanism, not just the intent.

## 11. ✅ DNS on `enp0s25` — RESOLVED & verified 2026-09-01

First real boot: `nmcli device status` showed `enp0s25` stuck as
`connected (externally)`, `/etc/resolv.conf` empty, worked around that
session with a manual `nameserver` line.

**Root cause found 2026-09-01:** `flush-network-before-switch-root` enumerated
interfaces with `awk`, but gawk was never in `boot.initrd.systemd.storePaths`
(only `ip` was). `path = [ … ]` only sets `$PATH` in a systemd initrd — it does
**not** copy the binary into the initrd image; only `storePaths` does. So `awk`
was "command not found", the `$(ip … | awk …)` list was empty, the loop never
ran, and nothing was ever flushed (`|| true` hid it) — the exact footgun
memory-alpha documented for `ip`, reintroduced by the generic loop. Commit
`9558203` drops awk and iterates `/sys/class/net/*` with pure shell `${p##*/}`,
so the script depends only on `ip`.

**Verified on the confirming reboot (2026-09-01):**

```
$ sudo dmesg | grep flush-network
[   80.340724] flush-network-before-switch-root: starting
[   80.514645] flush-network-before-switch-root: done      # ← ran, finally
$ nmcli device status
enp0s25  ethernet  connected  Wired connection 2            # ← not "externally"
$ cat /etc/resolv.conf
nameserver 192.168.8.1
nameserver fd2e:7702:f2a4::1                                # ← real, NM-generated
```

No manual `nameserver` workaround needed anymore. Lesson for the rest of the
fleet: any `boot.initrd.systemd.services.*` script that calls a non-systemd,
non-`ip` binary must add that binary to `storePaths` or it silently no-ops.

## 12. The *arr media stack (nixflix) — owner steps before first switch

Declared in `hosts/galactica/nixflix.nix` and wired into the flake, but
**nothing here activates until the secrets below exist** — sops-nix fails
activation on a missing secret, so `nrs` will refuse until step 2 is done.

Deliberately a **clean rebuild**: the old Unraid `arr_config` appdata is not
restored (it stays in `tank/backups/` as insurance only). Indexers, quality
profiles and download-client settings are re-entered through each service's
own UI; collections re-enter via *arr imports from `tank/media_staging`
(§9). Jellyfin and Seerr stay OFF on this host — no GPU, so playback remains
memory-alpha's job over the §8 NFS mounts.

### The one layout rule that matters

`media/` and `downloads/` must be **plain directories inside a single
dataset**, not datasets of their own. Hardlinks cannot cross a ZFS dataset
boundary, and the *arrs hardlink completed downloads into the library — split
them and nothing errors, imports just silently become full copies (double
disk for anything seeding, and slow). Do not "tidy up" by creating
`tank/nixflix_media/downloads` later.

1. [x] **Create the one dataset.** That is the whole step — one command:
   ```bash
   sudo zfs create tank/nixflix_media
   ```
   **Do not `mkdir` the directories underneath it.** nixflix creates every one
   of them at activation via systemd-tmpfiles, with ownership that a manual
   `mkdir` gets wrong (`root:media 0775` for the library and downloads roots,
   then per-service subdirectories owned `sonarr:media`, `qbittorrent:media`,
   `sabnzbd:media` and so on). A hand-made `root:root 0755` has no group write
   for `media`; tmpfiles does correct that on the next switch, so it is not
   destructive, just pointless work that obscures the real state if something
   misbehaves later. `/tank/appdata/nixflix` is likewise created for you —
   `tank/appdata` already exists (§9/§10) and is forced onto the special vdev's
   SSD mirror, which is why the *arr databases live there.

   The dataset itself is the exception because it is the one thing nixflix
   *cannot* make: the modules create directories, not ZFS datasets. Skip this
   and tmpfiles would quietly create `/tank/nixflix_media` as a plain directory
   inside the `tank` root dataset — which puts the library and downloads on
   different filesystems from each other only if you later split them, but
   more importantly loses the dataset's own properties and snapshot boundary.

2. [x] **Add the secrets** — `sops secrets/galactica.yaml`, all under a
   `nixflix:` key:

   | Secret | How to produce it |
   |---|---|
   | `protonWgConf` | The whole wg-quick file from Proton's portal, as a multi-line YAML value. ⚠ Must be a **P2P server that supports port forwarding**, or the NAT-PMP sidecar below has nothing to map. |
   | `prowlarrApiKey`, `sonarrApiKey`, `sonarrAnimeApiKey`, `radarrApiKey`, `lidarrApiKey` | `openssl rand -hex 16` each |
   | `sabnzbdApiKey`, `sabnzbdNzbKey` | `openssl rand -hex 16` each |
   | `arrPassword` | Any strong password — shared web-UI login (`admin`) across the *arrs |
   | `navidromePassword` | Any strong password — Navidrome's `z` admin login. ⚠ Applied at user **creation** only; changing it later needs Navidrome's own UI, not this secret. |
   | `qbittorrentPassword` | Any strong password — **plain text**, and must match the hash in step 3 |

   `openssl` is not installed everywhere in the fleet (serenity, notably).
   Where it is missing, these need nothing but coreutils:
   ```bash
   head -c 4000 /dev/urandom | LC_ALL=C tr -dc 'a-f0-9'    | head -c 32   # a 32-char hex API key
   head -c 4000 /dev/urandom | LC_ALL=C tr -dc 'A-Za-z0-9' | head -c 24   # a 24-char password
   ```
   The 4000-byte input is deliberate: `tr -dc` keeps only ~6% of random
   bytes for the hex class, so a smaller read silently yields a *short*
   key rather than failing.

3. [x] **Check qBittorrent's WebUI hash against the secret.** The
   `qbittorrentPassword` secret is what the *arrs and the NAT-PMP sidecar
   authenticate *with*; qBittorrent's own login is set separately, by
   `serverConfig.Preferences.WebUI.Password_PBKDF2` in `nixflix.nix`. That
   hash is **already committed** — it only needs regenerating if you change
   `qbittorrentPassword`:
   ```bash
   nix run git+https://codeberg.org/feathecutie/qbittorrent_password -- --password '<the same password>'
   ```
   (Codeberg has been flaky; the same digest is PBKDF2-HMAC-SHA512, 100000
   iterations, 64-byte key, random 16-byte salt, formatted
   `@ByteArray(<base64 salt>:<base64 key>)` — a dozen lines of Python's
   `hashlib` if the flake is unreachable.)

   ⚠ If the hash and the secret disagree, every *arr grab fails
   authentication and the sidecar never publishes a port — and neither
   failure is loud. Regenerate *both together* or neither.

4. [x] **Then switch**, and verify the pieces that can only be checked live:
   ```bash
   systemctl status wg.service qbittorrent sabnzbd sonarr sonarr-anime radarr lidarr prowlarr flaresolverr navidrome
   sudo ip netns exec wg curl -s -4 ifconfig.me  # ← Proton's IP, NOT the house IP
   curl -s -4 ifconfig.me                        # ← the house IP (host is untunnelled)
   journalctl -u protonvpn-natpmp -f             # ← "published forwarded port NNNNN"
   ```
   The second and third lines together are the kill-switch check: torrent
   traffic leaves via Proton while NFS/SSH/monitoring stay on the LAN.

   ⚠ `ip netns exec` needs root — without `sudo` it fails with `setting the
   network namespace "wg" failed: Operation not permitted`, which reads like
   a broken namespace and isn't. The other three lines are fine unprivileged.

   After that, `protonvpn-healthcheck` is the standing answer to the same
   question — a timer that reads wg0's last handshake age every 60s and
   fails the unit once it passes 240s:
   ```bash
   systemctl status protonvpn-healthcheck.timer
   systemctl start protonvpn-healthcheck && journalctl -u protonvpn-healthcheck -n 5
   ```
   A tunnel that dies *after* boot is otherwise silent: `wg.service` is a
   `RemainAfterExit` oneshot, so it keeps reporting `active (exited)` while
   qBittorrent's traffic is black-holed. The check turns that into a unit
   in `systemctl --failed`, which clears itself on the first run that passes.

   ⚠ `-4` is not decoration. Without it curl inside the namespace prefers
   IPv6 and reports a `2a02:6ea0:…` Proton address — reassuring, but it
   answers the wrong question: BitTorrent peer connections and the NAT-PMP
   forward are both IPv4, so IPv4 is the path the kill-switch check has to
   cover. Pin the family on *both* lines so the two results are comparable.

5. [x] **Add the twelfth secret and the DNS records, for Traefik.** The web
   UIs are reachable at `https://<service>.arr.internal` and
   `https://<service>.arr.zjones.dev` — `prowlarr`, `sonarr`, `sonarr-anime`,
   `radarr`, `lidarr`, `navidrome`, `sabnzbd`, `qbittorrent`, and `traefik`
   for the dashboard. The firewall opens **only 80 and 443**; the service
   ports are not reachable directly, by design.

   ⚠ **The usernames are not all the same.** Eight of the nine log in as
   `admin`; Navidrome logs in as **`z`**. That is deliberate — Navidrome is a
   personal listening account, with playlists, favourites and play counts
   bound to the user, rather than a service admin — but it is exactly the kind
   of difference that reads as a wrong password.

   | Service | User | Secret under `nixflix:` |
   |---|---|---|
   | Prowlarr, Sonarr, sonarr-anime, Radarr, Lidarr | `admin` | `arrPassword` (one value, shared) |
   | qBittorrent | `admin` | `qbittorrentPassword` |
   | **Navidrome** | **`z`** | `navidromePassword` |
   | SABnzbd | *(no login)* | API key only |
   | Traefik dashboard | *(no auth)* | — |

   Read any of them without opening the editor:
   ```bash
   sudo cat /run/secrets/nixflix/navidromePassword; echo
   ```
   The `echo` matters — the values carry no trailing newline, so the prompt
   lands on the same line and it is easy to copy one character short.

   Two prerequisites, neither of which the switch can do for itself:

   1. [x] `sops secrets/galactica.yaml` → add `cloudflare/apiToken`, the same
      DNS-edit token the other three Traefik hosts already use. Activation
      fails without it, like any other missing secret. Only the
      `*.arr.zjones.dev` certificates need it; `*.arr.internal` is served
      from Traefik's own self-signed cert and works with no token at all.
   2. [x] In AdGuard on hopper, point `*.arr.internal` and `*.arr.zjones.dev`
      at **192.168.8.190**. Until then the names do not resolve and nothing
      loads — which looks exactly like Traefik being broken.

   `homelab.letsencryptStaging` is still `true`, so the first certificates
   come from Let's Encrypt's **staging** CA and browsers will warn on the
   `.zjones.dev` names. That is the intended order: prove issuance works,
   then set it `false` for this host. Staging and production certs use
   separate storage (`acme-staging.json` / `acme.json`), so flipping never
   requires deleting anything.

   ⚠ Names are `*.arr.*`, not `*.galactica.*` like the rest of the fleet.
   They follow the media **stack** rather than the host, so moving it later
   is a DNS change instead of re-entering every URL in Prowlarr's
   application list and each *arr's cross-references.

   Verified live once both were in place — all nine names answer through
   Traefik, `302` for the *arrs, Navidrome and the dashboard, `303` for
   SABnzbd, `200` for qBittorrent. The last two are the ones worth noting:
   SABnzbd would have returned `403 Access denied - Hostname verification
   failed` without its `host_whitelist`, and qBittorrent `401 Unauthorized`
   without `HostHeaderValidation = false`, so those two settings are
   confirmed rather than assumed. Handy re-check, no DNS needed:
   ```bash
   for h in prowlarr sonarr sonarr-anime radarr lidarr navidrome sabnzbd qbittorrent traefik; do
     printf '%-14s %s\n' "$h" \
       "$(curl -k -sS -o /dev/null -w '%{http_code}' --max-time 5 "https://$h.arr.internal/" 2>&1)"
   done
   ```

6. [x] **Prove one wildcard issuance, then leave staging.** The first switch
   issued per-subdomain certificates alongside the wildcard, because Traefik
   skips a domain only once a covering cert is already stored — so on a cold
   start the subdomain routers won the race. Every `-dev` router now names the
   same `main`+`sans`, which dedupes them. To confirm before the CA changes:
   ```bash
   sudo rm /var/lib/traefik/acme-staging.json
   sudo systemctl restart traefik
   journalctl -u traefik -f
   ```
   Exactly one issuance for `arr.zjones.dev` + `*.arr.zjones.dev`, and no
   per-subdomain requests, means it holds.

   Confirmed on 2026-09-04: one `Obtaining bundled SAN certificate` for the
   pair, two DNS-01 challenges (the base name and the wildcard each need
   their own TXT), one `Server responded with a certificate`, and no
   per-subdomain issuance at all — against the first run, where `lidarr` and
   `sonarr-anime` were issued individually before the wildcard arrived.
   `homelab.letsencryptStaging = false` is now set in `configuration.nix`.
   Production uses `acme.json`, a separate file from `acme-staging.json`, so
   the switch needs nothing deleted and flipping back is enough to undo it.
   Worth having got right first: production allows 50 certificates per
   registered domain per week, and the un-deduped form spent ten.

7. [ ] **Let Recyclarr build the profiles before importing.** It syncs the
   TRaSH guides into Sonarr, sonarr-anime and Radarr — custom formats, scores,
   quality definitions, and one quality profile each — so the profiles the
   import needs are created rather than hand-entered:

   | Instance | Profile it creates |
   |---|---|
   | Sonarr | `WEB-1080p (Alternative)` |
   | sonarr-anime | `[Anime] Remux-1080p` |
   | Radarr | `[SQP] SQP-1 (1080p)` |

   It runs daily on a timer and once at boot, after each *arr's `-config`
   service. To do it now rather than wait:
   ```bash
   sudo systemctl start recyclarr && journalctl -u recyclarr -n 40
   ```
   Then check the profiles exist in each UI before step 8. Indexers still have
   to be added to Prowlarr by hand — Recyclarr does profiles, not indexers.

   ⚠ Recyclarr takes ownership of custom formats and scores
   (`delete_old_custom_formats` and `reset_unmatched_scores` are both on), so
   hand-edits to those are reverted on its next run. Quality profiles you make
   yourself are safe — `cleanupUnmanagedProfiles` is deliberately off, and
   turning it on would delete every profile the managed list does not name.

   To move to 4K, set `sonarrQuality`/`radarrQuality` in `nixflix.nix`; the new
   profile appears on the next run and existing files are untouched, so only
   newly-grabbed releases follow it.

8. [ ] **Import the staged media** — point Sonarr/Radarr at
   `tank/media_staging/*` and run their import, which hardlinks into
   `/tank/nixflix_media/media/{tv,movies}`. Only destroy the staging datasets
   once the libraries look right; that is the last undo.

9. [ ] **Bumping nixflix later is a deliberate, two-step move**, not a
   `nix flake update`. The input is pinned to an exact upstream revision that
   the fork's CI has cleared against 26.05. To move it: merge upstream into
   `zjones-xyz/nixflix-exp`, let its CI go green against the 26.05 pin, then
   set that same upstream rev here. A bare branch URL would let a routine
   update pull an unrehearsed revision into the fleet, which is precisely
   what the canary exists to prevent.

### Anime

`sonarr-anime` is enabled — a second Sonarr on port 8990 with its own root
folder (`media/anime`), which nixflix treats as a first-class service:
Prowlarr registers it as its own application and both download clients get a
matching category, so anime stays separated end to end.

**There is no `radarr-anime`, and adding one is not symmetric.** nixflix ships
no such module. The generic builder would happily produce one — it defines its
own systemd unit rather than wrapping nixpkgs' single-instance
`services.radarr`, so a second instance is architecturally fine — but the
*name* `sonarr-anime` is enumerated by hand in about fifteen places (Prowlarr's
application list, the qBittorrent and SABnzbd category maps, Recyclarr's
profiles, the UID table in `globals.nix`). A `radarr-anime` would run and be
reachable, and would be wired into none of them without local patches to each.

So anime films start in the **existing Radarr**, using their own root folder
(e.g. `media/anime-movies`) and an anime quality profile — the common
arrangement, since anime films are a far smaller category than series and
Radarr applies profiles per-movie. If that proves insufficient, a local
`radarr-anime` module plus the category/application wiring is the next step,
and would be a good upstream contribution: it fills a real asymmetry.

### Music — Lidarr and Navidrome, and the one real hazard

Navidrome (port 4533) streams the library; Lidarr (8686) acquires into it.
Navidrome runs *here* rather than on memory-alpha, unlike Jellyfin: audio
transcoding is cheap enough for this CPU, so the no-GPU argument that exiles
video playback does not apply, and serving from local disk skips an NFS hop.
Navidrome's `MusicFolder` follows Lidarr's root folder automatically, so the
two cannot drift apart.

⚠ **The existing music collection is the one genuinely irreplaceable thing in
this migration.** SHARES.md marks `music` 🛡 Protected, and the re-acquirable
table deliberately omits it — unlike `arr_media`, it cannot be re-downloaded.
Lidarr is not a read-only cataloguer: within its root folder it renames,
moves, and on upgrade deletes files.

So the config points Lidarr at a **fresh** `media/music`, and the old
collection stays where it is in `tank/media_staging`. When you do bring it
across, copy rather than move, and keep the staging copy until Lidarr has
matched the library and you have listened to a few albums:

```bash
# copy, do not move — the staging copy is the undo
rsync -a --info=progress2 /tank/media_staging/music/ /tank/nixflix_media/media/music/
```

Navidrome only ever reads the folder, so pointing *it* at the library is
risk-free; all the write authority is Lidarr's. If you would rather have
streaming now and defer the acquisition question, set
`nixflix.lidarr.enable = false` and give Navidrome an explicit
`settings.MusicFolder` pointing at the staging path — it does not need Lidarr
to work.

### FlareSolverr

Enabled, with two local corrections to upstream's wiring that
`hosts/galactica/nixflix.nix` explains at length. In short: upstream gives the
readiness probe 30 seconds, but FlareSolverr's startup includes a cold
Chromium launch measured at 43s on a *modern* cloud runner — and a failed
`ExecStartPost` kills the unit, so on this 2012 Xeon the stock timeout risks a
permanent restart-loop rather than a stumble. The probe is raised to 180s.
Separately, upstream makes `prowlarr-indexer-proxies` *require*
`flaresolverr.service`, so one failed start cancels the proxy-configuration
job outright and nothing ever re-queues it — Prowlarr comes up with no proxy
and stays that way silently. That is relaxed to `wants`, which is safe because
the script only ever calls Prowlarr's own API and saves with `forceSave=true`
(no validation call to the proxy).

Worth confirming on first boot: `journalctl -u flaresolverr` should show it
becoming ready once, not looping, and Prowlarr's Settings → Indexer Proxies
should list a `FlareSolverr` entry tagged `flaresolverr`.

**Not enabled, deliberately, each a few lines when wanted:** `lidarr`
(SHARES.md marks `music` 🛡 Protected — a curated library, so automating it
is its own decision) and `recyclarr` (TRaSH profile sync).
SABnzbd is deliberately **outside** the VPN — usenet is already TLS to a paid
provider, so the tunnel would only cap throughput; `nixflix.nix` says so at
the option.
