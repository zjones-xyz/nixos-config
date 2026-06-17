# Deploying hopper (Raspberry Pi 4)

hopper is an `aarch64-linux` host built with `raspberry-pi-nix`. The flow is:
bootstrap with the official NixOS aarch64 installer → enrol its sops key →
deploy normally with `nixos-rebuild --target-host` from then on.

---

## 0. Build host note: macOS 26 + linux-builder VM

> **macOS 26 (Darwin 25.x) known issue:** The `darwin.linux-builder` VM crashes
> immediately on macOS 26 due to a QEMU / Hypervisor.framework incompatibility
> (`HVF SMCR_EL1 assertion failed`). This affects both nixpkgs and
> nixpkgs-unstable as of June 2026.
>
> **The workaround is to build on the Pi itself** — see step 1 below.
> Once the linux-builder issue is resolved upstream, you can resume building
> from the Mac and shipping the closure via `--target-host`. At that point,
> register the builder by running `nix run nixpkgs#darwin.linux-builder` and
> adding the printed `builders = ...` line to `/etc/nix/nix.conf`.

---

## 1. Bootstrap: flash the official NixOS aarch64 image

Instead of building the sdImage from the Mac (blocked by the linux-builder
issue above), use the official NixOS aarch64 installer to get NixOS onto the
Pi, then switch to the hopper config directly on the hardware.

1. Download the official NixOS aarch64 SD image from
   [nixos.org/download](https://nixos.org/download) → "NixOS on ARM" →
   Raspberry Pi 4.

2. Flash it to the **USB SSD** (preferred over SD — rebuilds chew through SD
   cards):

   ```sh
   zstdcat nixos-*.img.zst | sudo dd of=/dev/disk/<SSD> bs=4M status=progress conv=fsync
   ```

   Replace `/dev/disk/<SSD>` with the real device (`diskutil list`).
   **Double-check the device** — `dd` to the wrong disk is unrecoverable.

3. Set the Pi 4 to boot USB-first (EEPROM `BOOT_ORDER=0xf41`) per the notes in
   [configuration.nix](configuration.nix), connect it to the network, and power
   it on.

## 2. First boot and networking

- The installer image comes up via DHCP as user `nixos` (no password).
- Add a **DHCP reservation** on the GL.iNet router so its IP is stable, and
  point `hopper.internal` at it (or rely on mDNS).
- Confirm SSH works:

  ```sh
  ssh nixos@hopper.internal
  ```

## 3. Switch to the hopper config (on the Pi)

SSH in and build directly on the Pi. The Nix binary cache supplies pre-built
aarch64-linux packages, so this is mostly downloading rather than compiling.

```sh
ssh nixos@hopper.internal
nix-shell -p git
git clone <your-nixos-config-repo-url> ~/nixos-config
cd ~/nixos-config
sudo nixos-rebuild switch --flake .#hopper
```

This replaces the installer system with the full hopper config. After it
completes, `ssh z@hopper.internal` works (your key is in `common.nix`).

## 4. Enrol hopper's sops key

Secrets are encrypted to hopper's SSH host key (as an age key), which only
exists after first boot. On hopper:

```sh
ssh-to-age < /etc/ssh/ssh_host_ed25519_key.pub
```

Then, in this repo on the Mac:

1. Paste that pubkey into [`.sops.yaml`](../../.sops.yaml), replacing the
   `&hopper` placeholder.
2. Create the real encrypted secrets file (replaces the plaintext placeholder):

   ```sh
   sops secrets/hopper.yaml
   ```

   Populate the keys the modules expect (see the placeholder file for the list):
   - `cloudflare/apiToken` — Cloudflare API token with DNS-edit perms (reuse
     memory-alpha's token); needed for the Let's Encrypt DNS challenge
   - `tailscale/authKey` — reusable/ephemeral key from the Tailscale admin console
   - `nut/upsmonPassword` — any password; matches the upsd user
   - `beszel/agentKey` — `KEY=ssh-ed25519 ...`, the Beszel hub's public key
   - `speedtest-tracker/appKey` — `APP_KEY=base64:...` (`openssl rand -base64 32`)

3. If you edited keys after creating the file: `sops updatekeys secrets/hopper.yaml`

## 4b. Cloudflare DNS records (for TLS certs)

Traefik requests a **Let's Encrypt wildcard cert** for `hopper.zjones.dev` via
the Cloudflare DNS-01 challenge. The challenge only needs DNS-edit permission on
the zone — the host does **not** need to be publicly reachable — but the A
records must exist so clients can resolve the names to hopper's private IP.

In the Cloudflare dashboard for `zjones.dev`, add (DNS-only / grey-cloud, **not**
proxied):

| Type | Name       | Content                      |
|------|------------|------------------------------|
| A    | `hopper`   | hopper's LAN or Tailscale IP |
| A    | `*.hopper` | hopper's LAN or Tailscale IP |

> The wildcard `*.hopper` covers `adguard.hopper.zjones.dev`, `beszel...`, etc.
> Pointing these at a private/tailnet IP is intentional — services stay off the
> public internet while still getting valid certs.

## 5. Redeploy with real secrets

Once sops is enrolled, redeploy so the secrets-dependent services (Tailscale,
Traefik, NUT, Beszel, speedtest-tracker) come up properly. From the Mac:

```sh
nixos-rebuild switch \
  --flake .#hopper \
  --target-host z@hopper.internal \
  --build-host z@hopper.internal \
  --use-remote-sudo
```

`--build-host z@hopper.internal` tells Nix to compile on the Pi and ship the
result there — no Mac builder VM needed. For subsequent deploys this is the
standard command.

## 6. Post-deploy checklist

- **Tailscale exit node:** approve it in the admin console
  (Machines → hopper → Edit route settings → Use as exit node).
- **DNS:** set hopper as the **primary** DNS server in the GL.iNet DHCP
  settings (hamilton secondary, once it exists). Verify:

  ```sh
  dig @hopper.internal example.com
  ```

- **NUT:** confirm the UPS is detected and adjust the driver/port if needed:

  ```sh
  nut-scanner -U
  upsc cyberpower@localhost
  ```

  Trigger a test notification by pulling UPS mains power briefly and confirm an
  ntfy push arrives on the `ups` topic.
- **Web UIs:** reachable via Traefik as `*.hopper.internal` (self-signed) and
  `*.hopper.zjones.dev` (Let's Encrypt) — `traefik`, `adguard`, `kuma`, `ntfy`,
  `beszel`, `speedtest`, and Homepage at the root `hopper.zjones.dev`.

## TLS certs: staging → production

The Traefik module ships with the **Let's Encrypt staging CA** pinned
(`acme.caserver=...staging...`) so debugging can't burn the strict production
rate limits. Staging certs are issued by an untrusted root, so browsers will
warn — that's expected. Use this phase to confirm the DNS challenge succeeds
(check `docker logs traefik` for "certificate obtained").

Once certs are issuing cleanly, switch to production:

1. Remove the `caserver` line from
   [`modules/nixos/traefik-local.nix`](../../modules/nixos/traefik-local.nix).
2. **Delete the cached staging certs** on hopper — Traefik won't re-request if a
   cert already exists in the file:

   ```sh
   ssh z@hopper.internal 'rm /home/z/traefik/letsencrypt/acme.json'
   ```

3. Redeploy. Traefik requests fresh production certs on startup.

## Routine updates

From the Mac, once hopper is running:

```sh
git pull
nixos-rebuild switch \
  --flake .#hopper \
  --target-host z@hopper.internal \
  --build-host z@hopper.internal \
  --use-remote-sudo
```

No reflashing — that's only for the initial install or a corrupted disk. If the
macOS linux-builder issue is resolved and you'd prefer to build on the Mac
instead of the Pi, drop `--build-host` and configure the builder per the note
in section 0.
