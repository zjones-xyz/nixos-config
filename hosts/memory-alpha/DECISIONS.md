# memory-alpha — decision log

Each entry: **decision → alternatives → rationale.** Companion documents:
`HARDWARE-MAP.md` (what is plugged into what), `MANUAL-STEPS.md` (owner steps).

Dates are UTC.

---

## 1. Bambuddy and Obico's ML API run as OCI containers, not Nix packages

**Pinned upstream images under `virtualisation.oci-containers`**
(`bambuddy.nix`, `obico.nix`). *Alt:* nixpkgs `pkgs.bambuddy`, a
`package.nix` of our own, or native packaging of the ML API.

Surveyed 2026-09-26 against nixpkgs `nixos-26.05` and `master`, NUR and GitHub.

### Bambuddy

- `pkgs.bambuddy` exists only on `master` (NixOS/nixpkgs#522032, merged
  2026-07-01, after the 26.05 branch-off, with no backport).
- It is at 1.2.5.1 against upstream 1.2.5.6. The bump to 1.2.5.5
  (NixOS/nixpkgs#552387) has been open since 2026-08-13.
- It has one maintainer.
- There is no `services.bambuddy` NixOS module.
- Upstream ships no flake. NUR and GitHub have only personal configs.

Adopting it now would mean an overlay from `master` or a forked `package.nix`,
plus a hand-written module. We would then chase upstream's roughly weekly
releases ourselves, one step behind a package that is already behind.

**Revisit when** a stable channel (26.11) carries `pkgs.bambuddy` *and* a
`services.bambuddy` module exists. At that point, switch. Nothing here
depends on the container beyond `bambuddy.nix`. The data directory, ipvlan and
virtual-printer addresses would carry over.

### Obico ML API

- Nothing exists in nixpkgs, NUR or upstream.
- The only Obico item in nixpkgs is `octoprint.python.pkgs.obico`, the
  printer-side OctoPrint plugin, which does not apply here.

Native packaging is feasible, since Flask, gunicorn, onnxruntime and OpenCV are
all in nixpkgs. It is not worth it:

- Upstream pins Python 3.8 and old library versions that would need relaxing
  and re-verifying.
- The model weights are fetched at image-build time, so each would need a
  hash-pinned fetch.
- There are no releases to track, only commit SHAs, and nobody else would
  share the maintenance.

The CPU-only image is already self-contained, and `obico.nix` pins it by
digest.

**Revisit only if** upstream starts versioning `ml_api`, or someone packages it.

### Slicer sidecars

The same verdict holds for `slicers.nix`. nixpkgs has the `orca-slicer` and
`bambu-studio` desktop apps, but not maziggy's HTTP wrappers around their CLIs.
Those are one Node app, built from an unmerged fork branch of AFKFelix's
`orca-slicer-api`, bundled with each slicer's upstream AppImage. Upstream pins
the pair to each Bambuddy release (`bambuddy-<version>` tags). Packaging it
ourselves would mean a Node build plus keeping two slicer versions in step with
Bambuddy's profile handling. The images already do that.

**Revisit when** the wrapper's patches land upstream and it gets packaged.

---

## 2. The slicer sidecars share the maker slice's CPU quota

**The slicers join `system-maker.slice` on its existing quota**, shared with
Bambuddy and Obico. That quota is `CPUQuota = "150%"`, deliberately stingy (see
`configuration.nix`). *Alt:* a slice of their own.

The slicers run only on demand (§3), so the quota is shared only while one is
loaded. The quota exists for Jellyfin (HARDWARE-MAP.md §4): it caps the maker
containers at 1.5 of the 8 threads, so they can't eat the 15–28 W package
budget that Quick Sync transcodes share. Slicing doesn't change that. It is
CPU-heavy but bursty and started by hand, and a capped slicing job just takes
longer while someone waits for it. The one cost is inside the slice: slicing
during a print can slow Obico's failure checks until the job finishes.

**Revisit if** slicing gets slow enough to be annoying, or Obico misses
failures while a slice runs. Raising the shared quota is the planned first
step. If only the contention with Obico bites, give the slicers their own
slice instead.

---

## 3. The slicer sidecars load on demand and unload when idle

**systemd socket activation in front of each container** (`slicers.nix`). A
connection starts it, and `systemd-socket-proxyd --exit-idle-time=30min`
stops it again. *Alt:* always-on containers, as in the compose stack.

The owner asked for this. The images are heavy (OrcaSlicer and BambuStudio
behind Node), slicing is occasional, and a cold-start delay is an acceptable
price for nothing resident between slices. Bambuddy only calls the sidecars
when a user acts (slice dialog, preset lookup, support bundle). It never polls
them (checked in 1.2.5.6), so idle really is idle. A slice keeps its proxy
alive through its progress polling.

What it costs:
- **A cold start before the first call.** The slice dialog's first calls
  time out at 10 s; the slice itself waits. A support bundle's 2 s probe
  always reports idle sidecars as unreachable. MANUAL-STEPS.md §2 measures the
  real cold start.
- **No Traefik route.** Traefik routes come from container labels, and a
  stopped container has none. A file-provider route to the socket would need
  `modules/nixos/traefik.nix` to take extra files, a fleet-wide change for a
  health endpoint nobody browses.
- **Bambuddy reaches them through the host**, at `host.docker.internal:1300x`
  over the trusted `br-proxy` bridge, not by container name.

**Revisit if** cold starts routinely exceed Bambuddy's 10 s. Raise the idle
timeout first; go back to always-on only if that doesn't help.
