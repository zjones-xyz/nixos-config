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

## 8. memory-alpha's NFS mounts — the cutover plan (decided 2026-08-31)

`hosts/memory-alpha/configuration.nix` mounts `tower.internal:/mnt/user/jellyfin`
and `tower.internal:/mnt/user/arr_managed_data` over NFSv4, and `README.md`
confirms `tower.internal` keeps resolving to this box. The mounts are `soft`
+ `x-systemd.automount` + `noauto`, so memory-alpha degrades rather than
hangs when Unraid goes away — but Jellyfin's library and the *arr stack's
managed data stay empty until galactica exports the equivalent paths again.

**`services.nfs.server.enable` and firewall port 2049 are already live** in
`configuration.nix` (don't depend on the array existing). What's still
blocked on the array's dataset paths:

- **Preserve all four recorded `fsid`s**, not just the two with a confirmed
  consumer — `SHARES.md` §4's own reasoning: it costs nothing, and a wrong
  or missing `fsid` hands a client `ESTALE` instead of a clean remount.

  | fsid | Share | Consumer |
  |---|---|---|
  | 100 | `arr_media` | unconfirmed |
  | 101 | `jellyfin` | memory-alpha, `/mnt/unmanaged` |
  | 102 | `arr_managed_data` | memory-alpha, `/mnt/arr_managed_data` |
  | 103 | `bambuddy_library` | unconfirmed |

- **Export scope: LAN-wide**, not restricted to memory-alpha specifically —
  decided over the tighter option since the two unconfirmed consumers might
  be elsewhere on the LAN. Use the actual subnet (`192.168.8.0/24`,
  confirmed from live host addresses this session), not a bare `*`, so this
  doesn't reach past the LAN if the firewall posture ever changes.
- **Template**, to fill in once the array's dataset paths and pool name are
  chosen (neither decided yet — that's its own open item, see §9):
  ```nix
  services.nfs.server.exports = ''
    /<pool>/arr_media          192.168.8.0/24(rw,sync,no_subtree_check,fsid=100)
    /<pool>/jellyfin           192.168.8.0/24(rw,sync,no_subtree_check,fsid=101)
    /<pool>/arr_managed_data   192.168.8.0/24(rw,sync,no_subtree_check,fsid=102)
    /<pool>/bambuddy_library   192.168.8.0/24(rw,sync,no_subtree_check,fsid=103)
  '';
  ```
Plan this as an explicit cutover step alongside §9, not an afterthought once
the array exists — memory-alpha's Jellyfin/`*arr` stack has no working
media the entire time between "Unraid goes away" and "this lands."

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
   nixarr gets a clean `/tank/media`; collections re-enter via *arr imports.
   ✅ 2026-09-02 — all seven (8.94 T) staged; `tank/media`/`tank/books` empty.
   ⚠ `tank/media` was since renamed to `tank/nixarr_media` (2026-09-03,
   `media.nix` updated to match) — `tank/books` is unaffected.
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
4. [ ] **NFS re-exports** (§8, fsids 100–103) — and re-point memory-alpha's
   mounts, which still reference the dead Unraid paths
   (`tower.internal:/mnt/user/...`).

## 10. nixarr — declarative media stack (media.nix, scaffolded)

`hosts/galactica/media.nix` is now wired into `configuration.nix` and
evaluates/activates cleanly as-is (Sonarr/Radarr/Prowlarr/Bazarr/
Audiobookshelf/Shelfmark/recyclarr, no VPN/download client yet). Before it's
actually useful:

1. [ ] Confirm `stateDir = "/tank/appdata/arr_config"` against the real
   dataset tree (`zfs list -r tank/appdata` on galactica) — the path is a
   best guess from SHARES.md's old Unraid classification, not verified
   against what the 2026-09-02 dataset-tree build actually created.
2. [ ] Reconcile Shelfmark's fixed library path
   (`/tank/nixarr_media/library/{books,audiobooks}`) with the real
   `tank/books` dataset — mountpoint override or symlink, owner's call.
3. [ ] Decide the real download-client inbox path — nixarr hardcodes
   `${mediaDir}/qbittorrent` and `${mediaDir}/usenet`, neither configurable.
4. [ ] Generate a ProtonVPN WireGuard config (P2P-tagged server), add it to
   `secrets/galactica.yaml` under `vpn/wgConf`, then flip `vpnReady = true`
   in `media.nix` to bring up qBittorrent/SABnzbd inside the VPN-Confinement
   netns.
5. [ ] Flesh out `recyclarr.configuration` with real TRaSH-guide
   `quality_definition`/`custom_formats`/`quality_profiles` blocks — the
   scaffold is a no-op until then.
6. [ ] Ingress: point the `homelab_stacks` tsdproxy List-provider entries at
   the new localhost ports (Sonarr 8989, Radarr 7878, Prowlarr 9696, Bazarr
   6767, Audiobookshelf, Shelfmark) — out of scope for this repo.

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
