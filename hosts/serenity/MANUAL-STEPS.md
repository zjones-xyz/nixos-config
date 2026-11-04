# serenity — manual steps

Steps that can't be expressed in the flake, or that need Zoe at the Mac.

## 1. ✅ Colima: first start — done 2026-09-16

Colima's VM state (`~/.colima/`, `~/.lima/`) lives outside the flake. Only the
binaries are declared (see `DECISIONS.md` §1).

The first `colima start --cpus 2 --memory 4 --disk 30` took 30s, including the
VM image download. Those flags are saved to `~/.colima/default/colima.yaml`, so
a plain `colima start` reuses them. The defaults would have been 2 GiB RAM
(tight for Qdrant plus a client) and a 100 GiB disk (sparse, but it can be grown
and never shrunk). To resize: `colima stop`, then `colima start --memory 6`
(or `colima start --edit`).

The smoke test passed on the hardware: `colima start` made `colima` the active
docker context (no `DOCKER_HOST`), the engine inside the VM was docker 29.2.1 on
linux/arm64, `docker run --rm hello-world` pulled and ran the arm64 image, and
`qdrant/qdrant` on `-p 6333:6333` answered `healthz check passed` at
`http://localhost:6333/healthz`. After `docker rm -f qdrant && colima stop`, the
context switched back to `default`. The Qdrant image stays cached in the VM.

**Day-to-day:** `colima start` … `colima stop`. Nothing autostarts at login. If
`docker` says it failed to connect to `unix:///var/run/docker.sock`, the VM is
simply not running.

If a workshop image turns out to be amd64-only, recreate the VM with Rosetta
enabled: `colima delete`, then `colima start --vz-rosetta` with the flags above.
`colima delete` wipes all images and volumes.

## #166 Bambuddy's CA in OrcaSlicer's `printer.cer`

`modules/darwin/slicer-certs.nix` appends `certs/bambuddy-vp-ca.crt` to the
OrcaSlicer cask's `Contents/Resources/cert/printer.cer` on
every switch, unless it's already there. Without it, connecting to a Bambuddy
virtual printer fails with `code=-1`. A cask upgrade or in-app update undoes
it until the next switch.

1. [ ] System Settings → Privacy & Security → App Management: allow the
       terminal you run `darwin-rebuild` from. Without it macOS blocks edits
       inside `/Applications/*.app`, and the switch prints
       `warning: could not update …`.
2. [ ] Switch, fully quit OrcaSlicer (Cmd+Q), then check the last entry is
       `CN=Virtual Printer CA …` with the fingerprint Bambuddy shows:
       ```sh
       while openssl x509 -noout -subject -sha256 -fingerprint; do :; done \
         < /Applications/OrcaSlicer.app/Contents/Resources/cert/printer.cer
       ```
3. [ ] Launch it. The edit breaks the bundle's code-signature seal. A
       launched-before app normally doesn't care, but a freshly upgraded
       (quarantined) one may be refused as "damaged". If so,
       `xattr -dr com.apple.quarantine /Applications/OrcaSlicer.app`.

## #236 PWAsForFirefox — first switch

Background: DECISIONS.md §2.

1. [ ] Before switching, check whether `/Applications/Firefox.app` was
   installed by hand (`brew list --cask firefox` fails if so). If it was,
   quit Firefox and delete the app. Profiles live in `~/Library` and stay.
   Otherwise the `firefox` cask won't install over it and `brew bundle`
   fails the switch.
2. [ ] Switch serenity. Check that
   `~/Library/Application Support/Mozilla/NativeMessagingHosts/firefoxpwa.json`
   resolves (`cat` it).
3. [ ] In Firefox, install the **PWAsForFirefox** extension from
   addons.mozilla.org. In its setup, let it **install the runtime**. On
   macOS that step is required, unlike on pegasus.
4. [ ] Install a first app from the extension's toolbar button. It should
   appear in `~/Applications`. Launch it: the window title should be the
   app's name, and the titlebar shouldn't take the site's colour.
5. [ ] Optional, per app whose icon looks off: same as pegasus
   MANUAL-STEPS.md §#236, step 4.
