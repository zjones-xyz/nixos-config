# Deploying hamilton (Raspberry Pi 3 — backup DNS)

> **Placeholder name.** This host is scaffolded as `hamilton`; rename it (hostname,
> flake output, `secrets/hamilton.yaml`, `.sops.yaml` regex, the `nrs`/`nrt` aliases)
> once the real unit is in hand. The commands below use `hamilton`.

hamilton is an `aarch64-linux` host built from nixos-hardware's `raspberry-pi-3`
profile plus nixpkgs' `sd-image-aarch64` module — **not** raspberry-pi-nix,
which doesn't support the Pi 3. It runs only AdGuard Home + Unbound (a backup
resolver) and a Tailscale client. The flow mirrors hopper: flash once to
bootstrap → enrol its sops key → deploy with `nixos-rebuild --target-host`.

> **Build host note:** hamilton is `aarch64-linux`. A macOS workstation can't build it
> natively. Build on an aarch64 Linux machine (the Pi itself via `--build-host`,
> or another arm64 box), or use a Mac-hosted Linux builder VM — see below.

---

## 0. Build host: Nix + linux-builder on an Apple Silicon Mac

Identical to hopper — see
[hosts/hopper/DEPLOY.md](../hopper/DEPLOY.md#0-build-host-nix--linux-builder-on-an-apple-silicon-mac)
for the full steps. In short:

1. Install Nix on the Mac (not installed by default):

   ```sh
   curl --proto '=https' --tlsv1.2 -sSf -L https://install.determinate.systems/nix | sh -s -- install
   ```

2. Start + register the builder VM (Apple Silicon builds aarch64 natively):

   ```sh
   nix run nixpkgs#darwin.linux-builder
   ```

   Add the printed `builders = ...` line to `/etc/nix/nix.conf` (or use
   nix-darwin's `nix.linux-builder.enable = true;`).

3. Run the commands below on the Mac; Nix offloads to the VM.

> A Pi 3 is very slow to build on itself, so `--build-host z@hamilton.internal` works
> but the Mac builder VM is much more pleasant here.

---

## 1. Build and flash the bootstrap image

The Pi 3 boots from **SD card** (USB boot is unreliable on this board):

```sh
nix build .#nixosConfigurations.hamilton.config.system.build.sdImage
```

The image lands in `./result/sd-image/*.img.zst`. Flash it to the SD card:

```sh
zstdcat result/sd-image/*.img.zst | sudo dd of=/dev/disk/<SD> bs=4M status=progress conv=fsync
```

Replace `/dev/disk/<SD>` with the real device (`lsblk` / `diskutil list`).
**Double-check the device** — `dd` to the wrong disk is unrecoverable.

Insert the card, connect to the network, and power on.

## 2. First boot and networking

- hamilton comes up via DHCP. Add a **DHCP reservation** on the GL.iNet router so its
  IP is stable.
- Confirm SSH works (your key from `common.nix` is already authorized):

  ```sh
  ssh z@hamilton.internal
  ```

## 3. Enrol hamilton's sops key

Secrets are encrypted to hamilton's SSH host key (as an age key), which only exists
after first boot. On hamilton:

```sh
ssh-to-age < /etc/ssh/ssh_host_ed25519_key.pub
```

Then, in this repo:

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

## 3b. Cloudflare DNS records (for TLS certs)

Traefik requests a **Let's Encrypt wildcard cert** for `hamilton.zjones.dev` via
the Cloudflare DNS-01 challenge. The challenge only needs DNS-edit permission on
the zone — the host does **not** need to be publicly reachable — but the A
records must exist so clients can resolve the name to hamilton's private IP.

In the Cloudflare dashboard for `zjones.dev`, add (DNS-only / grey-cloud, **not**
proxied):

| Type | Name              | Content                          |
|------|-------------------|----------------------------------|
| A    | `hamilton`        | hamilton's LAN or Tailscale IP   |
| A    | `*.hamilton`      | hamilton's LAN or Tailscale IP   |

> The wildcard `*.hamilton` covers `adguard.hamilton.zjones.dev`. Pointing it at
> a private/tailnet IP is intentional — the UI stays off the public internet
> while still getting a valid cert.

## 4. Deploy

From a build host that can produce aarch64 derivations:

```sh
nixos-rebuild switch \
  --flake .#hamilton \
  --target-host z@hamilton.internal \
  --use-remote-sudo
```

- Add `--build-host z@hamilton.internal` to build *on the Pi* instead of locally
  (slow on a Pi 3 — a remote/local aarch64 builder is friendlier).
- Use `boot` instead of `switch` if a change needs a reboot.

Locally on hamilton you can also use the `nrs` / `nrt` aliases from
[home.nix](home.nix).

## 5. Post-deploy checklist

- **Tailscale:** plain client (not an exit node) — no admin-console approval
  needed. Confirm it joined the tailnet: `tailscale status`.
- **DNS failover:** in the GL.iNet DHCP settings, set hamilton as the **secondary**
  DNS server (primary = hopper). That's the entire failover mechanism. Verify
  hamilton resolves on its own:

  ```sh
  dig @hamilton.internal example.com
  ```

- **AdGuard UI:** fronted by Traefik (`traefik-hamilton.nix`) at
  `adguard.hamilton.internal` (self-signed) and `adguard.hamilton.zjones.dev`
  (Let's Encrypt). `dns.nix` binds AdGuard to localhost; Traefik proxies to it.
  Config is declarative (`mutableSettings = false`), so the UI is effectively
  read-only for settings — client names and filter lists live in `dns.nix`
  (shared with hopper), not the UI.

## TLS certs: staging → production

Like hopper, the Traefik module here pins the **Let's Encrypt staging CA** so
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
git pull          # on the build host
nixos-rebuild switch --flake .#hamilton --target-host z@hamilton.internal --use-remote-sudo
```

No reflashing — that's only for the initial install or a corrupted card.
