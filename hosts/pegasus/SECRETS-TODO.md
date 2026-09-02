# pegasus — secrets to provision

No key material was generated or committed by the authoring session. The sops +
Tailscale wiring in `configuration.nix` is gated on `secrets/pegasus.yaml`
existing, so the closure evaluates without it; provisioning it activates the
wiring automatically.

## Tailscale auth key (required for headless join)

1. [ ] After the first boot, get pegasus's age key from its SSH host key:
       `ssh-to-age < /etc/ssh/ssh_host_ed25519_key.pub`
2. [ ] In `.sops.yaml`, replace the `pegasus` placeholder key with that value
       and add `*pegasus` to the `secrets/pegasus.yaml` creation rule (a rule +
       placeholder are already stubbed in — see below).
3. [ ] Create the encrypted file from the Mac (admin age key):
       `sops secrets/pegasus.yaml` and add:
       ```yaml
       tailscale:
         authKey: tskey-auth-xxxxxxxxxxxx
       ```
       Generate a reusable/ephemeral auth key in the Tailscale admin console.
4. [ ] `sops updatekeys secrets/pegasus.yaml`, commit, deploy. Until then, run
       `tailscale up --ssh` once interactively on the box.

## Borgmatic offsite backup (hosts/pegasus/borgmatic.nix)

1. [x] Generate a dedicated ed25519 keypair — do NOT reuse Tower's borgmatic
       key or z's own SSH key:
       ```sh
       ssh-keygen -t ed25519 -f pegasus-borgmatic -N ""
       ```
2. [x] Create the `pegasus-home` repo on BorgBase (see
       `hosts/galactica/borgmatic/README.md` for the account, if it doesn't
       exist yet) and register `pegasus-borgmatic.pub` as its append-only key.
3. [x] `sops secrets/pegasus.yaml` and add:
       ```yaml
       borgmatic:
         passphrase: <a new, distinct passphrase — do not reuse Tower's>
         ssh_key: |
           <contents of pegasus-borgmatic, the private half>
       ```
4. [x] `sops updatekeys secrets/pegasus.yaml`, commit, deploy.
5. [x] On pegasus, once deployed:
       `ssh-keyscan <borgbase-host> | sudo tee -a /var/lib/borgmatic/ssh/known_hosts`
       (not secret — doesn't go through sops; `sudo` is needed since
       sops-nix creates `/var/lib/borgmatic/ssh/` as root, and the plain
       `>>` redirect form doesn't work through `sudo` — the shell opens
       that file with the calling user's permissions before `sudo` runs).
6. [ ] Turn on BorgBase's own inactivity alerting for this repo in its UI
       (docs/BACKUP.md §6) — that's the monitoring signal this config relies
       on; no ntfy/Kuma hook is wired for it.
7. [x] Run the first backup by hand and time it before trusting the systemd
       timer's default schedule:
       `borgmatic -c /etc/borgmatic.d/pegasus-home.yaml create`.
8. [ ] Periodically trigger BorgBase's server-side compaction for this repo
       (its UI: More > Compact repo, from the repo table) to reclaim the
       disk space `prune` frees up logically but can't free physically over
       an append-only key. `prune` itself already runs automatically every
       night per `keep_daily`/`keep_weekly`/`keep_monthly` in
       `hosts/pegasus/borgmatic.nix` — only `compact` is skipped there,
       since it silently no-ops over an append-only key. No key changes
       needed for this: BorgBase's dashboard button runs with its own
       authority, not through pegasus's SSH key at all.

## Beszel agent key (optional — enables monitoring from hopper's hub)

`modules/nixos/beszel-agent.nix` is imported but stays completely inert until
this secret exists: it greps the committed `secrets/pegasus.yaml` for a
`beszel:` key (sops encrypts values, not key names) and only then declares the
secret and enables the unit. Declaring a sops secret that isn't in the file
fails *activation*, so this ordering is deliberate — a `nixos-rebuild switch`
before you do this is a no-op, not a breakage.

1. In the Beszel hub (hopper), add a new system and copy the public key it
   shows you.
2. `sops secrets/pegasus.yaml` and add — note the `KEY=` prefix, the value is
   consumed as a systemd `EnvironmentFile`, not as bare YAML:
   ```yaml
   beszel:
     agentKey: KEY=ssh-ed25519 AAAA...
   ```
3. Commit and switch. The agent starts on its own.
4. In the hub, point the system at pegasus's **tailnet** address. Port 45876 is
   deliberately not opened on the LAN — the hub dials the agent, and
   `tailscale0` is already a trusted interface on this host.

## Inference API keys (only if used)

If any upstream that Olla fronts needs an API key (e.g. a hosted endpoint added
later), add it to `secrets/pegasus.yaml` and reference it from
`modules/nixos/olla-router.nix`. The current config (local ollama + the LAN 1070
node) needs none.

## Reminder

`keys/` (SSH keypairs) and plaintext secret values must never be committed.
`secrets/*.yaml` are sops-encrypted only.
