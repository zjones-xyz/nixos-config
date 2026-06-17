# Deploying hopper (Raspberry Pi 4)

hopper is an `aarch64-linux` host built with `raspberry-pi-nix`. The flow is:
bootstrap with nixos-anywhere (using Raspberry Pi OS as the carrier OS) →
enrol its sops key → deploy normally with `nixos-rebuild --target-host` from
then on.

---

## 0. Build host note: macOS 26 + linux-builder VM

> **macOS 26 (Darwin 25.x) known issue:** The `darwin.linux-builder` VM crashes
> immediately on macOS 26 due to a QEMU / Hypervisor.framework incompatibility
> (`HVF SMCR_EL1 assertion failed`). This affects both nixpkgs and
> nixpkgs-unstable as of June 2026.
>
> **The workaround is `nixos-anywhere --build-on-remote`** — see step 1 below.
> This builds on the Pi itself and ships the closure locally, so no Mac builder
> VM is needed.
>
> Once the linux-builder issue is resolved upstream, you can resume building
> from the Mac and shipping the closure via `--target-host`. At that point,
> register the builder by running `nix run nixpkgs#darwin.linux-builder` and
> adding the printed `builders = ...` line to `/etc/nix/nix.conf`.

---

## 1. Bootstrap: install via nixos-anywhere

Because the official NixOS aarch64 installer ships as a `.zst` SD image that
can be hard to find, and the generic ISO won't boot on a Pi (no EFI), we use
**nixos-anywhere** on top of **Raspberry Pi OS** as the carrier OS.

### 1a. Flash Raspberry Pi OS to the USB SSD

Raspberry Pi OS is the carrier OS — nixos-anywhere will wipe it and replace it
with NixOS. Use the Pi's SD card slot as a staging medium, or flash directly to
the USB SSD if you have a USB adapter.

1. Download **Raspberry Pi OS Lite (64-bit)** from
   [raspberrypi.com/software](https://www.raspberrypi.com/software/operating-systems/)
   — choose the "Lite" (no desktop) variant.

2. Flash it to the **SD card** with Raspberry Pi Imager (or `dd`). In Imager's advanced settings:
   - Set hostname: `hopper`
   - Enable SSH (key-based)
   - Paste your public key (same key already in `modules/nixos/common.nix`)

3. Insert/attach the SSD, connect hopper to the network, power it on.

4. Add a **DHCP reservation** on the GL.iNet router so hopper's IP is stable,
   and point `hopper.internal` at it (or rely on mDNS).

5. Confirm SSH works:

   ```sh
   ssh pi@hopper.internal
   ```

   (Default user is `pi` on Raspberry Pi OS if you didn't override it in
   Imager; or whatever username you set.)

### 1b. Run nixos-anywhere

From this repo on the Mac:

```sh
nix run nixpkgs#nixos-anywhere -- \
  --flake .#hopper \
  --build-on-remote \
  --target-host pi@hopper.internal \
  --ssh-option StrictHostKeyChecking=no
```

`--build-on-remote` builds NixOS on the Pi itself (no Mac builder needed).
`nixos-anywhere` will:
1. Copy the flake to the Pi.
2. Run disko to partition and format `/dev/sda`.
3. Install NixOS and reboot.

> **Heads up:** disko will **wipe `/dev/mmcblk0`** (the SD card) completely.
> Confirm with `lsblk` on the Pi before proceeding.

After the reboot, SSH in as your normal user:

```sh
ssh z@hopper.internal
```

## 2. Enrol hopper's sops key

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

## 2b. Cloudflare DNS records (for TLS certs)

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

## 3. Redeploy with real secrets

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
result there — no Mac builder VM needed. This is the standard command for all
subsequent deploys too.

## 4. Post-deploy checklist

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

No reflashing or re-running disko — that's only for the initial install.
If the macOS linux-builder issue is resolved and you'd prefer to build on the
Mac instead of the Pi, drop `--build-host` and configure the builder per the
note in section 0.
