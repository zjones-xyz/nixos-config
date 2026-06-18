# Deploying hamilton (Raspberry Pi 3 — backup DNS)

hamilton is an `aarch64-linux` host built from nixos-hardware's `raspberry-pi-3`
profile plus nixpkgs' `sd-image-aarch64` module — **not** raspberry-pi-nix,
which doesn't support the Pi 3. It runs AdGuard Home + Unbound (backup DNS
resolver) and Tailscale. The flow mirrors hopper: build a complete SD image on
**memory-alpha** (which emulates aarch64 via binfmt) → flash it → boot straight
into the full hamilton config → enrol its sops key → deploy with
`nixos-rebuild --target-host`.

---

## 0. Build host: memory-alpha (not the Mac, not the Pi)

> **macOS 26 (Darwin 25.x) known issue:** The `darwin.linux-builder` VM crashes
> immediately on macOS 26 due to a QEMU / Hypervisor.framework incompatibility
> (`HVF SMCR_EL1 assertion failed`). This affects both nixpkgs and
> nixpkgs-unstable as of June 2026.
>
> **memory-alpha is the aarch64 build host instead.** It registers QEMU
> user-mode emulation via `boot.binfmt.emulatedSystems = [ "aarch64-linux" ]`
> (see its `configuration.nix`), so it can build aarch64 closures and images.
> This matters even more for hamilton than hopper — a Pi 3 is slow enough that
> building on the device itself is genuinely painful. Emulated builds on
> memory-alpha are far faster.

---

## 1. Bootstrap: build and flash the hamilton SD image

The Pi 3 boots from **SD card** (USB boot is unreliable on this board).

### 1a. Build the image on memory-alpha

SSH into memory-alpha, clone this repo, and build hamilton's SD image. Because
memory-alpha has aarch64 binfmt emulation, this just works:

```sh
ssh z@memory-alpha.internal
nix-shell -p git    # if git isn't already available
git clone <your-nixos-config-repo-url> ~/nixos-config
cd ~/nixos-config
nix build .#nixosConfigurations.hamilton.config.system.build.sdImage
```

The finished image lands in `result/sd-image/*.img.zst`.

### 1b. Flash it to the SD card

Copy the image off memory-alpha (or flash from memory-alpha directly if the
card reader is attached there). To flash from the Mac:

```sh
scp z@memory-alpha.internal:~/nixos-config/result/sd-image/*.img.zst .
diskutil list                      # find the SD card device
diskutil unmountDisk /dev/diskN
zstdcat *.img.zst | sudo dd of=/dev/diskN bs=4M status=progress conv=fsync
```

**Double-check the device** — `dd` to the wrong disk is unrecoverable.

### 1c. First boot

This image *is* the full hamilton config — there's no separate "switch to the
real config" step. Insert the card, connect hamilton to the network, power it on.

1. Add a **DHCP reservation** on the GL.iNet router so hamilton's IP is stable,
   and point `hamilton.internal` at it (or rely on mDNS).
2. Confirm SSH works (your key is baked in via `common.nix`):

   ```sh
   ssh z@hamilton.internal
   ```

## 2. Enrol hamilton's sops key

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

## 2b. Cloudflare DNS records (for TLS certs)

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

## 3. Redeploy with real secrets

Once sops is enrolled, redeploy so Tailscale and Traefik come up properly.
From the Mac, with memory-alpha as the aarch64 build host:

```sh
nixos-rebuild switch \
  --flake .#hamilton \
  --target-host z@hamilton.internal \
  --build-host z@memory-alpha.internal \
  --use-remote-sudo
```

`--build-host z@memory-alpha.internal` offloads the aarch64 build to
memory-alpha and ships the closure to hamilton — no Mac builder needed, and the
slow Pi 3 never compiles. This is the standard command for all subsequent deploys.

## 4. Post-deploy checklist

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
  --build-host z@memory-alpha.internal \
  --use-remote-sudo
```

No reflashing — that's only for the initial install or a corrupted card.
