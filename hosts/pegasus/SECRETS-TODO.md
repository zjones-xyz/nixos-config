# pegasus — secrets to provision

No key material was generated or committed by the authoring session. The sops +
Tailscale wiring in `configuration.nix` is gated on `secrets/pegasus.yaml`
existing, so the closure evaluates without it; provisioning it activates the
wiring automatically.

## Tailscale auth key (required for headless join)

1. After the first boot, get pegasus's age key from its SSH host key:
   `ssh-to-age < /etc/ssh/ssh_host_ed25519_key.pub`
2. In `.sops.yaml`, replace the `pegasus` placeholder key with that value and add
   `*pegasus` to the `secrets/pegasus.yaml` creation rule (a rule + placeholder
   are already stubbed in — see below).
3. Create the encrypted file from the Mac (admin age key):
   `sops secrets/pegasus.yaml` and add:
   ```yaml
   tailscale:
     authKey: tskey-auth-xxxxxxxxxxxx
   ```
   Generate a reusable/ephemeral auth key in the Tailscale admin console.
4. `sops updatekeys secrets/pegasus.yaml`, commit, deploy. Until then, run
   `tailscale up --ssh` once interactively on the box.

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
