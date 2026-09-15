# memory-alpha — manual steps

Human steps this host's Nix config cannot do for itself. Numbered checkboxes so
they can be ticked off while keeping the order, per `CLAUDE.md`.

This file was created alongside the Home Assistant work, so §1 is all there is
so far. Fleet-wide reasoning for that migration lives in
`docs/HOME-ASSISTANT-MIGRATION.md`; this file is only the doing.

Dates are UTC.

---

## 1. Home Assistant — bringing the migrated config across

`modules/nixos/home-assistant.nix` is live on this host, so after a switch
there is a **running but empty** Home Assistant on `ha.memory-alpha.internal`.
That is the intended state: §11 of the migration doc builds the new instance
alongside the Pi, which stays authoritative until step 1.9 below.

⚠ **Nothing here touches the Pi's live instance until 1.9.** Steps 1.1–1.8 are
reversible by deleting a directory.

### 1.1 Prerequisites, still open

1. [ ] Confirm whether Zigbee runs through **ZHA or a Zigbee2MQTT add-on** —
   decides whether the mesh restores with `/config` or needs
   `services.zigbee2mqtt`. Either way, **do not change stacks during the
   move** (migration doc §7.1).
2. [ ] Identify the **Zigbee coordinator chip**, which sets how cleanly a
   network restore lands on a replacement coordinator (§6.1).
3. [ ] List the **add-ons in use** and which hold state worth carrying. This is
   the only part of the migration with no shortcut (§8).

### 1.2 Copy the config off the Pi

4. [ ] Take a **full backup** from the Pi's UI and land the tarball on
   `ha_backup` on `tank` — the share exists for this.
5. [ ] **Stop Home Assistant on the Pi** before copying. `docs/BACKUP.md` §4d:
   a file-level copy of a live SQLite database is not a backup, and `/config`
   holds two (the recorder DB, and `zigbee.db` under ZHA).
6. [ ] Copy `/config` into `/home/z/home-assistant/config` on this host —
   either from the Pi's Samba/SSH add-on, or by extracting the backup
   tarball's inner `homeassistant.tar.gz`, which *is* `/config`.
   ⚠ `.storage/` is the part that matters: config entries, long-lived tokens,
   and the ZHA network state that saves re-pairing the mesh. Preserve it.
   The module creates the directory but never chowns it — HA runs as root in
   the container and owns `/config`, so copy as root and leave it that way.

### 1.3 Two edits the module cannot make

`/config` is migrated mutable state, so `configuration.yaml` is not managed by
Nix under this deployment form. These are hand-edits, once.

7. [ ] **Tell HA it is behind a proxy**, or every request through Traefik comes
   back 400:

   ```yaml
   http:
     use_x_forwarded_for: true
     trusted_proxies:
       - 172.16.0.0/12   # the docker bridge Traefik reaches it from
       - 127.0.0.1
   ```

8. [ ] **Extract the plaintext `secrets.yaml`** that arrives with the migrated
   config into `secrets/memory-alpha.yaml` (sops). ⚠ A step, not a follow-up:
   left alone, the plaintext lives on inside LUKS *and* in every borg archive
   from the next nightly run onward.

### 1.4 Then, and only then

9. [ ] **Uncomment the recorder DB** in `hosts/memory-alpha/borgmatic.nix` —
   it is commented precisely because borgmatic's sqlite hook fails the whole
   nightly run on a missing file, which would take every other database on
   this host down with it. Uncomment in the PR that lands the migrated config,
   not before.
10. [ ] Verify against the **still-running Pi**: integrations loaded, no repair
    warnings, automations listed, history present, discovery populated (the
    test for whether host networking is doing its job), mobile app
    reconnecting.
11. [ ] Move the `homeassistant.internal` rewrite in
    `hosts/galactica/configuration.nix` from `192.168.8.142` to
    `192.168.8.99`. ⚠ **Last**, after verification — it is the cutover, and
    also the whole rollback.
12. [ ] Keep the Pi shut down but **intact** through at least one full cold
    boot of this host. That boot is the event the migration doc's §3.1 is
    about, and the Pi is a complete rollback for the price of one DNS line.

### 1.5 Not done here, on purpose

- **The admin homepage entry** (`hosts/galactica/homepage/admin/services.yaml`)
  is deliberately not added yet — it would link a service that is empty until
  step 1.2. Add it with the cutover.
- **Bluetooth and Zigbee** are not plumbed into the container at all. Neither
  radio moves to this host: Zigbee gets a network-attached coordinator,
  Bluetooth gets ESPHome proxies. `home-assistant.nix` says so where someone
  would otherwise "fix" the omission; migration doc §6 has the argument.
- **`services.esphome`**, which the Bluetooth proxies need, is not yet on this
  host. It is the next piece of Nix work and has hardware lead time in front
  of it (§12 steps 7–8).
