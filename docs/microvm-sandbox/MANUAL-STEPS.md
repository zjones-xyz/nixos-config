# microvm-sandbox — manual steps

Things that can't be done from this authoring session (no access to Pegasus hardware,
no fleet secrets) or that are one-time operator actions. Filled in as each phase lands;
empty sections below are placeholders for phases not yet implemented.

## Phase 0 — none

Pure documentation phase; nothing to do on hardware yet.

## Phase 1 — guest boot

Code has landed (`modules/nixos/microvm-sandbox.nix`, Pegasus instantiation). Before the
first `nixos-rebuild switch --flake .#pegasus` that picks this up:

1. **Create the two new btrfs subvolumes on the real disk** (the `fileSystems.*` entries in
   `hardware-configuration.nix` mount them but don't create them — mirrors how `@games` was
   handled during the original bring-up):
   ```
   mount /dev/mapper/cryptroot /mnt   # or wherever it's mounted at subvol=/ (top-level)
   btrfs subvolume create /mnt/@microvm-store
   btrfs subvolume create /mnt/@microvm-state
   umount /mnt
   ```
   (Adjust the mount invocation to however you're already accessing the top-level subvolume
   on a live Pegasus — the exact incantation depends on whether you're doing this from a
   running system or a rescue environment.)
2. **Confirm KVM is actually usable for an unprivileged/cloud-hypervisor launch** (not just
   that `kvm-amd` is loaded) — `ls -l /dev/kvm` and permissions for whatever user/group
   cloud-hypervisor runs the guest as.
3. **Confirm the `10.100.0.0/24` addressing doesn't collide with Pegasus's actual LAN
   subnet** (GL.iNet router DHCP range — not recorded in this repo). If it does collide,
   the `hostAddress`/`guestAddress` options in `homelab.agentSandbox` need different values
   before first boot.
4. Verify guest boot, writable `/nix` (`nix build` a trivial derivation inside the guest —
   reachable via the host: `microvm -c agent-sandbox` or the console microvm.nix wires up;
   check `microvm.nix`'s own docs for the exact console/login mechanism, since Phase 1 sets
   up no SSH/agent user yet), and outbound internet from the guest.
5. **Reminder — Phase 1 has no network containment.** The guest can currently reach the LAN
   and tailnet; Phase 2 adds the denylist. Don't leave a Phase-1-only guest running
   unattended past this verification.

## Phase 2 — network policy (once code lands)

- From inside the guest: confirm internet reachable; confirm **every other fleet host is
  unreachable** (memory-alpha, hopper, hamilton, Serenity, and Pegasus's own
  LAN/tailnet addresses/services including Olla:40114) — this is the containment proof,
  test it explicitly, don't assume the rules are right from reading them.
  Suggested checks from inside the guest:
  ```
  curl -sS -m5 https://cache.nixos.org > /dev/null && echo "internet: OK"
  ping -c1 -W2 100.<memory-alpha-tailnet-ip> && echo "LEAK: tailnet reachable" || echo "tailnet: blocked (expected)"
  curl -sS -m3 http://<pegasus-tailnet-ip>:40114 && echo "LEAK: Olla reachable" || echo "Olla: blocked (expected)"
  ```
- Confirm the forwarded dev port is reachable from Pegasus itself but from nowhere else
  (not the LAN, not the tailnet) — test from a second fleet host, expect failure.
- Confirm the above holds with Docker running on Pegasus (not just at idle) — Docker's own
  iptables management is a known risk flagged in DECISIONS.md.

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
