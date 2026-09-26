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
