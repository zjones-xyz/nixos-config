# microvm-sandbox — manual steps

Things that can't be done from this authoring session (no access to Pegasus hardware,
no fleet secrets) or that are one-time operator actions. Filled in as each phase lands;
empty sections below are placeholders for phases not yet implemented.

## Phase 0 — none

Pure documentation phase; nothing to do on hardware yet.

## Phase 1 — guest boot — ✅ VERIFIED on Pegasus (2026-07-20/21)

**Gate passed.** All three criteria confirmed live — see `DECISIONS.md`'s "Phase 1 —
operator verification" section for the full account, including three real bugs found and
fixed along the way (missing-subvolume emergency-mode risk, `systemd-networkd` deleting
Tailscale's ip rules, `microvm`-user permission denied on fresh subvolumes). What follows
is the as-verified checklist, kept for anyone re-running this from scratch (e.g. after a
reinstall) rather than a still-open TODO:

1. **Create the two btrfs subvolumes on the real disk before first switch** — this step
   was missed during the actual first attempt and cascaded into a host-wide emergency-mode
   boot (see `DECISIONS.md`). `nofail` is now on both mounts specifically so a repeat of
   this mistake degrades to "guest doesn't start" instead of "Pegasus doesn't boot," but
   doing this step first is still the right move:
   ```
   mount /dev/mapper/cryptroot /mnt   # or wherever it's mounted at subvol=/ (top-level)
   btrfs subvolume create /mnt/@microvm-store
   btrfs subvolume create /mnt/@microvm-state
   umount /mnt
   ```
2. KVM access, `nixos-rebuild switch --flake .#pegasus`, and the `10.100.0.0/24` addressing
   all confirmed clean on real hardware (LAN is `192.168.8.x`–`192.168.10.x`, no collision).
3. **Confirmed: there is no genuine interactive console into the guest** — the systemd unit
   wires the guest's console up as journal *output* only (no `StandardInput=`), so nothing
   can be typed into it. Phase 1's gate (writable `/nix`, `nix build`, outbound internet)
   was verified instead via an automated boot-time self-check
   (`systemd.services.phase1-verify` in the guest module) whose `PASS`/`FAIL` surfaces
   through `journalctl -u microvm@agent-sandbox` on the host. This stays in place until
   Phase 3's SSH makes direct interactive checks possible.
4. **Confirmed: `microvm@<name>.service` has `restartIfChanged = false`.** A host
   `nixos-rebuild switch` does **not** restart an already-running guest — pick up any
   guest-internal config change with an explicit
   `sudo systemctl restart microvm@agent-sandbox` afterward.
5. **Phase 1 has no network containment** (confirmed: wide-open NAT egress). The guest can
   currently reach the LAN and tailnet — Phase 2 adds the denylist. Don't leave a
   Phase-1-only guest running unattended.

## Phase 2 — network policy — ✅ VERIFIED on Pegasus (2026-07-21)

**Gate passed.** `networking.firewall.extraCommands`/`extraStopCommands` in
`modules/nixos/microvm-sandbox.nix` insert `-I FORWARD 1` DROP rules for the tap
interface against 100.64.0.0/10 (tailnet CGNAT) and the three RFC1918 ranges, ahead of
`networking.nat`'s own blanket per-interface ACCEPT (confirmed by reading
`nat-iptables.nix` directly — that ACCEPT has no destination filtering of its own, which
is exactly why Phase 1's egress was wide-open). **Scoped down from the original plan**:
the forwarded-dev-port mechanism is deferred to Phase 3 — `networking.nat.forwardPorts`
turned out to be the wrong tool (it unconditionally exposes the port via the *external*
interface, i.e. the whole LAN, not "host-only"), and there's nothing listening on the
guest yet to meaningfully test a hand-rolled loopback-DNAT alternative against. See
`DECISIONS.md` for the full reasoning.

**Getting to a genuine pass took three rounds, two of them real bugs in the test itself
rather than the firewall rules** — full account in `DECISIONS.md`'s Phase 2 verification
section. Briefly: (1) testing this host's own addresses doesn't exercise `FORWARD` at all
(local-to-host traffic goes to `INPUT` instead) — looked like a pass, wasn't; (2) the
self-check's `timeout 3 bash -c ...` calls failed instantly because `bash` wasn't in the
systemd unit's `path` — also looked like a pass (a fast failure reads the same as a
blocked connection from the script's own text), confirmed by a positive control hitting
the identical error. Both fixed. **Final result**, definitive because it's the counters,
not the self-check's text: `iptables -L FORWARD -n -v` shows all four `agentvm0` DROP
rules at `6 packets / 360 bytes` each (SYN retransmissions during the 3s test window) —
nonzero, real. Rule positioning was independently confirmed correct throughout (sitting
above `DOCKER-USER`, `DOCKER-FORWARD`, `ts-forward`, and `nixos-filter-forward`), and
Docker was running the whole time (always-on fleet-wide) — first confirmed, not just
hoped-for, evidence the two coexist without conflict.

**Lesson worth generalizing**: a self-check "passing" is not proof on its own for anything
security-relevant. Always cross-check an independent signal (here, the iptables counters)
and include a positive control proving the test mechanism itself works before trusting
the result — this is what caught bug 2 above, which otherwise would have looked identical
to a real pass.

To re-run this verification from scratch:
```
sudo systemctl restart microvm@agent-sandbox   # pick up the guest config
journalctl -u microvm@agent-sandbox -f          # watch for PHASE2-VERIFY: lines
```
Expect: `internet OK`, then four `timed out (expected)` lines each ~3 seconds apart (not
near-instant — that would indicate the bash-in-path bug has regressed), then `PASS`. Then
confirm with the counters directly:
```
sudo iptables -L FORWARD -n -v | head -10
```
All four DROP rules for `agentvm0` should show nonzero packet/byte counts. Zero counters
mean the check didn't actually exercise the rules — don't treat a "PASS" as sufficient on
its own.

## Phase 3 — agent user, Docker, agents (once code lands)

- **Mint `CLAUDE_CODE_OAUTH_TOKEN`** — see SECRETS-TODO.md.
- **Mint the Codex token** — see SECRETS-TODO.md.
- **Generate the guest's own SSH host key ceremony** — see SECRETS-TODO.md (this is the
  guest's sops age identity; must happen before its `secrets/<guest>.yaml` can be created).
- Confirm from Pegasus: `ssh -J z@pegasus.<tailnet> agent@<guest-ip>` reaches the guest;
  add the `sandbox` Host alias to `~/.ssh/config` on Serenity (see the plan's "Operator
  access" section for the exact stanza).
- Confirm a Docker Postgres container comes up inside the guest.
- Confirm a sample web dev server is reachable on the forwarded port from Pegasus.
- Confirm Claude Code authenticates headlessly using the subscription token (not an API key).

## Phase 4 — build-verification (once code lands)

- Inside the guest as `agent`: `nix flake check` against a checkout of this flake, with
  **no sops age keys present** on the guest — confirm it still passes (this is the point
  of the exercise: the guest can validate configs without holding any fleet secrets).
- `nix build .#nixosConfigurations.<host>.config.system.build.toplevel` for an x86_64 host
  (pegasus or memory-alpha — not hopper/hamilton without binfmt) to completion, pulling
  from `cache.nixos.org`.

## Phase 5 — snapshot/reset + docs (once code lands)

- Take a first btrbk snapshot of the guest's state volume; confirm it lands in
  `/.snapshots` (Pegasus's existing `@snapshots` subvolume) and is listed by the `btrbk`
  CLI.
- Do one full rollback drill: intentionally modify something inside the guest's state
  volume, stop the guest, restore the snapshot, restart, confirm the change is gone.
- Confirm `nix eval` succeeds for the memory-alpha 4 GB stub (evaluated only — not booted,
  not deployed).
