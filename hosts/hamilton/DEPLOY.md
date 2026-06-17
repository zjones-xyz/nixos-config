# Deploying hamilton (Raspberry Pi 3 — backup DNS)

> **Placeholder name.** This host is scaffolded as `hamilton`; rename it (hostname,
> flake output, `secrets/hamilton.yaml`, `.sops.yaml` regex, the `nrs`/`nrt` aliases)
> once the real unit is in hand. The commands below use `hamilton`.

hamilton is an `aarch64-linux` host built from nixos-hardware's `raspberry-pi-3`
profile plus nixpkgs' `sd-image-aarch64` module — **not** raspberry-pi-nix,
which doesn't support the Pi 3. It runs AdGuard Home + Unbound (backup DNS
resolver) and Tailscale. The flow: bootstrap with the official NixOS aarch64
installer → enrol its sops key → deploy with `nixos-rebuild --target-host`.

---

## 0. Build host note: macOS 26 + linux-builder VM

> **macOS 26 (Darwin 25.x) known issue:** The `darwin.linux-builder` VM crashes
> immediately on macOS 26 due to a QEMU / Hypervisor.framework incompatibility
> (`HVF SMCR_EL1 assertion failed`). This affects both nixpkgs and
> nixpkgs-unstable as of June 2026.
>
> **The workaround is to build on the Pi itself** — see steps 1–3 below. A Pi 3
> is slower than a Pi 4, but the Nix binary cache means most packages are
> downloaded rather than compiled, so it's manageable.
>
> Once the linux-builder issue is resolved upstream, drop `--build-host` from
> the deploy command and configure the VM per hopper's
> [section 0](../hopper/DEPLOY.md#0-build-host-note-macos-26--linux-builder-vm).

---

## 1. Bootstrap: flash the official NixOS aarch64 image

The Pi 3 boots from **SD card** (USB boot is unreliable on this board).

1. Download the official NixOS aarch64 SD image from
   [nixos.org/download](https://nixos.org/download) → "NixOS on ARM" →
   Raspberry Pi 3. (The same aarch64 image works for both Pi 3 and Pi 4.)

2. Flash it to the SD card:

   ```sh
   zstdcat nixos-*.img.zst | sudo dd of=/dev/disk/<SD> bs=4M status=progress conv=fsync
   ```

   Replace `/dev/disk/<SD>` with the real device (`diskutil list`).
   **Double-check the device** — `dd` to the wrong disk is unrecoverable.

3. Insert the card, connect to the network, and power on.

## 2. First boot and networking

- The installer image comes up via DHCP as user `nixos` (no password).
- Add a **DHCP reservation** on the GL.iNet router so its IP is stable, and
  point `hamilton.internal` at it (or rely on mDNS).
- Confirm SSH works:

  ```sh
  ssh nixos@hamilton.internal
  ```

## 3. Switch to the hamilton config (on the Pi)

SSH in and build directly on the Pi. The Nix binary cache supplies pre-built
aarch64-linux packages, so this is mostly downloading rather than compiling —
though a Pi 3 is slower than a Pi 4, so expect it to take longer.

```sh
ssh nixos@hamilton.internal
nix-shell -p git
git clone <your-nixos-config-repo-url> ~/nixos-config
cd ~/nixos-config
sudo nixos-rebuild switch --flake .#hamilton
```

After it completes, `ssh z@hamilton.internal` works (your key is in `common.nix`).

## 4. Enrol hamilton's sops key

Secrets are encrypted to hamilton's SSH host key (as an age key), which only
exists after first boot. On hamilton:

```sh
ssh-to-age < /etc/ssh/ssh_host_ed25519_key.pub
```

Then, in this repo on the Mac:

1. Paste that pubkey into [`.sops.yaml`](../../.sops.yaml), replacing the
   `&hamilton` placeholder.
2. Create the real encrypted secrets file (replaces the plaintext placeholder):

   ```sh
   sops secrets/hamilton.yaml
   ```

   hamilton needs two secrets:
   - `cloudflare/apiToken` — Cloudflare API token with DNS-edit perms (reuse
     memory-alpha's token); needed for the Let's Encrypt DNS challenge
   - `tailscale/authKey` — reusable/ephemeral key from the Tailscale admin console

3. If you edited keys after creating the file: `sops updatekeys secrets/hamilton.yaml`

## 4b. Cloudflare DNS records (for TLS certs)

Traefik requests a **Let's Encrypt wildcard cert** for `hamilton.zjones.dev` via
the Cloudflare DNS-01 challenge. The challenge only needs DNS-edit permission on
the zone — the host does **not** need to be publicly reachable — but the A
records must exist so clients can resolve the name to hamilton's private IP.

In the Cloudflare dashboard for `zjones.dev`, add (DNS-only / grey-cloud, **not**
proxied):

| Type | Name         | Content                        |
|------|--------------|--------------------------------|
| A    | `hamilton`   | hamilton's LAN or Tailscale IP |
| A    | `*.hamilton` | hamilton's LAN or Tailscale IP |

> The wildcard `*.hamilton` covers `adguard.hamilton.zjones.dev`. Pointing it at
> a private/tailnet IP is intentional — the UI stays off the public internet
> while still getting a valid cert.

## 5. Redeploy with real secrets

Once sops is enrolled, redeploy so Tailscale and Traefik come up properly.
From the Mac:

```sh
nixos-rebuild switch \
  --flake .#hamilton \
  --target-host z@hamilton.internal \
  --build-host z@hamilton.internal \
  --use-remote-sudo
```

`--build-host z@hamilton.internal` builds on the Pi itself — no Mac builder VM
needed. For subsequent deploys this is the standard command.

## 6. Post-deploy checklist

- **Tailscale:** plain client (not an exit node) — no admin-console approval
  needed. Confirm it joined the tailnet: `tailscale status`.
- **DNS failover:** in the GL.iNet DHCP settings, set hamilton as the **secondary**
  DNS server (primary = hopper). That's the entire failover mechanism. Verify
  hamilton resolves on its own:

  ```sh
  dig @hamilton.internal example.com
  ```

- **AdGuard UI:** fronted by Traefik at `adguard.hamilton.internal` (self-signed)
  and `adguard.hamilton.zjones.dev` (Let's Encrypt). Config is declarative
  (`mutableSettings = false`) — client names and filter lists live in `dns.nix`
  (shared with hopper), not the UI.

## TLS certs: staging → production

Like hopper, the Traefik module pins the **Let's Encrypt staging CA** so
debugging can't burn production rate limits. Staging certs trip browser warnings
— expected. Confirm issuance with `docker logs traefik` on hamilton.

To switch to production:

1. Remove the `caserver` line from
   [`modules/nixos/traefik-hamilton.nix`](../../modules/nixos/traefik-hamilton.nix).
2. Delete the cached staging cert (Traefik won't re-request otherwise):

   ```sh
   ssh z@hamilton.internal 'rm /home/z/traefik/letsencrypt/acme.json'
   ```

3. Redeploy.

## Routine updates

```sh
git pull
nixos-rebuild switch \
  --flake .#hamilton \
  --target-host z@hamilton.internal \
  --build-host z@hamilton.internal \
  --use-remote-sudo
```

No reflashing — that's only for the initial install or a corrupted card.
