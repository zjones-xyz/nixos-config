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

Also worth doing, since it's cheap and this is the containment-critical phase: confirm
this holds with Docker running on Pegasus (not just at idle) — Docker's own iptables
management is a known risk flagged in DECISIONS.md, and Docker is always-on fleet-wide so
every test here already includes it, but worth being deliberate about checking.

### Cold-boot rule-ordering bug, found by a genuine reboot test (2026-07-21)

The "not yet done as a genuine cold-boot test" gap above was closed by an actual `reboot`
(combined with testing the LUKS remote-unlock path) — and it found a real bug: on cold
boot, `ts-forward`/`DOCKER-USER`/`DOCKER-FORWARD` land **above** the four FORWARD DROP
rules (opposite of every prior switch-based verification), because `firewall.service`
runs early on a cold boot, before `docker.service`/`tailscaled.service` exist to install
their own top-of-chain hooks. Containment happened to still hold (nonzero DROP counters,
self-check passed) because Docker/Tailscale's chains don't match this traffic and fall
through — but that's incidental, not structural. Full account in `DECISIONS.md`'s
"cold-boot rule-ordering bug" section.

**Fixed** with a new `agent-sandbox-containment-reassert` oneshot service that re-runs the
same rule-insertion script `after = docker.service, tailscaled.service, firewall.service`
— guaranteeing final position on top regardless of cold-boot vs. switch ordering.

**To verify this fix**, after pulling the latest branch and
`nixos-rebuild switch --flake .#pegasus`, a genuine `reboot` is the only real test (a
switch+restart cycle would pass regardless, by the same warm-ordering coincidence that
hid the original bug). After reboot:
```
systemctl status agent-sandbox-containment-reassert --no-pager
sudo iptables -L FORWARD -n -v | head -15
sudo iptables -L INPUT -n -v | head -15
```
Expect the four FORWARD DROP rules and the INPUT DROP rule back on top, ahead of
`DOCKER-USER`/`DOCKER-FORWARD`/`ts-forward`/`nixos-filter-forward` and
`ts-input`/`nixos-fw` — matching the very first Phase 2 verification, not the inverted
order the cold-boot test found.

**✅ VERIFIED, gate closed for real this time (2026-07-21)**: a second genuine reboot
confirmed it — `agent-sandbox-containment-reassert` ran successfully (38s after boot),
and both chains came back correctly ordered: FORWARD's four DROP rules on top of
`DOCKER-USER`/`ts-forward`/`DOCKER-FORWARD`/`nixos-filter-forward`, and INPUT's blanket
DROP on top of `ts-input`/`nixos-fw`. This is now confirmed to hold on a genuine cold
start, not just a warm switch+restart.

### Critical fix: INPUT-chain containment bypass (2026-07-21)

An independent code review (requested before continuing past this gate) found that this
host's own listening services — sshd (port 22, `services.openssh.openFirewall` defaults
to `true` fleet-wide) and Steam Remote Play (27036/27037, from `gaming.nix`) — were
reachable **directly from the guest**, bypassing every FORWARD-chain rule above. Traffic
to Pegasus's own tap address (`10.100.0.1`) never enters `FORWARD` at all (see the
Phase 2 design note above) — it goes to `INPUT`, and nothing there was denying it. See
DECISIONS.md's new "critical containment bypass" section for the full account, including
the `nix eval` facts confirmed independently before accepting the finding.

**Fixed** with a blanket `iptables -I INPUT 1 -i agentvm0 -j DROP` rule (same
delete-then-insert idempotency pattern as the FORWARD rules), plus forcing
`net.ipv6.conf.all.forwarding = false` on the host as a bundled hardening.
`phase2-verify` gained a fifth regression check specifically targeting
`10.100.0.1:22` — the exact address:port the bypass exploited.

**To verify this fix on Pegasus**, after pulling the latest branch and
`nixos-rebuild switch --flake .#pegasus`:
```
sudo systemctl restart microvm@agent-sandbox
journalctl -u microvm@agent-sandbox -f          # watch for the 5th PHASE2-VERIFY line
```
Expect the new line: `timed out (expected) - this host's own gateway (INPUT-chain path,
not FORWARD) (10.100.0.1:22)`. Then confirm with the counter directly (the actual proof):
```
sudo iptables -L INPUT -n -v | grep agentvm0
```
Should show a nonzero packet/byte count on the DROP rule after `phase2-verify` has run.

**✅ VERIFIED, gate closed a second time (2026-07-21)**: the new regression check timed
out at the full 3s (not an instant tooling failure), and `iptables -L INPUT -n -v` showed
`18 packets / 1032 bytes` on the rule for `agentvm0` — nonzero, genuine proof against real
connection attempts.

## Phase 3 — agent user, Docker, agents (code landed 2026-07-21, not yet verified live)

Code lands `agent` user, Docker, sshd, `impermanence`-backed persistence, and
`CLAUDE_CODE_OAUTH_TOKEN` wiring — designed and `nix flake check`-verified but not yet
booted on real hardware. Codex's token is NOT yet wired (see SECRETS-TODO.md — its auth
flow turned out to be file-based and mismatched with sops-nix's model, needs a decision
first). Verification steps once switched:

1. `nixos-rebuild switch --flake .#pegasus`, then restart the guest to pick up the new
   guest-internal config (a host switch alone doesn't restart an already-running guest —
   `microvm@<name>.service` has `restartIfChanged = false`, confirmed back in Phase 1):
   ```
   sudo systemctl restart microvm@agent-sandbox
   journalctl -u microvm@agent-sandbox -f
   ```
2. **Confirm the guest's SSH host key persists across a restart** — this is the whole
   point of the `impermanence` wiring. Read it, restart the guest again, confirm it's
   identical:
   ```
   # (however you reach a shell in the guest at this point in Phase 3 —
   # journalctl-based visibility only, until SSH is confirmed working below)
   cat /etc/ssh/ssh_host_ed25519_key.pub
   sudo systemctl restart microvm@agent-sandbox
   # ... re-check the same file matches ...
   ```
3. **Confirm SSH access**: `ssh -J z@pegasus.<tailnet> agent@10.100.0.2` (or from Pegasus
   directly: `ssh agent@10.100.0.2`) using the Serenity key already wired into
   `operatorSshKeys`. Add a `sandbox` Host alias to `~/.ssh/config` on Serenity once this
   works (see the original plan's "Operator access" section for the exact stanza).
4. **Confirm Docker works and persists**: `docker run hello-world` inside the guest, then
   restart the guest and confirm `docker ps -a`/images survive (proves
   `/persist/var/lib/docker` is actually being used, not the ephemeral root).
5. **Confirm the agent's home directory persists**: create a file in `/home/agent`,
   restart the guest, confirm it's still there.
6. **Mint and wire `CLAUDE_CODE_OAUTH_TOKEN`** — see SECRETS-TODO.md §1-2 (guest's own
   sops age identity ceremony, then the token itself). Confirm after switching again:
   ```
   ssh agent@<guest> 'echo $CLAUDE_CODE_OAUTH_TOKEN | head -c 20'  # should print, not be empty
   claude --version   # then a real headless auth check
   ```
7. **Decide + implement Codex's token flow** — see SECRETS-TODO.md §3 for the three
   options; not done yet.
- Confirm a Docker Postgres container comes up inside the guest.
- Confirm a sample web dev server is reachable on the forwarded port from Pegasus — **not
  yet implemented**: the forwarded-dev-port mechanism itself (deferred from Phase 2) still
  needs the hand-rolled loopback-DNAT rule mentioned in Phase 2's design notes.

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
