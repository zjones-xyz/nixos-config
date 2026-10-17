# pegasus — secrets to provision

`secrets/pegasus.yaml` exists (sops-encrypted, committed) and `.sops.yaml`
carries pegasus's real age key, so the sops + Tailscale wiring in
`configuration.nix` is live. What remains below is unchecked items only.

## ✅ Tailscale auth key (required for headless join)

1. [x] After the first boot, get pegasus's age key from its SSH host key:
       `ssh-to-age < /etc/ssh/ssh_host_ed25519_key.pub`
2. [x] In `.sops.yaml`, replace the `pegasus` placeholder key with that value
       and add `*pegasus` to the `secrets/pegasus.yaml` creation rule.
3. [x] Create the encrypted file from the Mac (admin age key):
       `sops secrets/pegasus.yaml` and add:
       ```yaml
       tailscale:
         authKey: tskey-auth-xxxxxxxxxxxx
       ```
       Generate a reusable/ephemeral auth key in the Tailscale admin console.
4. [x] `sops updatekeys secrets/pegasus.yaml`, commit, deploy.

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

## Inference API keys (only if used)

If any upstream that Olla fronts needs an API key (e.g. a hosted endpoint added
later), add it to `secrets/pegasus.yaml` and reference it from
`modules/nixos/olla-router.nix`. The current config (local ollama + the LAN 1070
node) needs none.

## Reminder

`keys/` (SSH keypairs) and plaintext secret values must never be committed.
`secrets/*.yaml` are sops-encrypted only.
