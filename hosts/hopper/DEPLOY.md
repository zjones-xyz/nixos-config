# Deploying hopper (Raspberry Pi 4)

hopper is an `aarch64-linux` host built with `raspberry-pi-nix`. The flow is:
flash an image once to bootstrap → enrol its sops key → deploy normally with
`nixos-rebuild --target-host` from then on.

> **Build host note:** hopper is `aarch64-linux`. A macOS workstation can't build
> it natively. Build on an aarch64 Linux machine (the Pi itself via
> `--build-host`, or another arm64 box), or use a Mac-hosted Linux builder VM —
> see below. The commands below assume you run them somewhere that can produce
> aarch64 derivations.

---

## 0. Build host: Nix + linux-builder on an Apple Silicon Mac

On an Apple Silicon Mac you can build aarch64-linux **natively** (no emulation)
via a small NixOS builder VM that your Mac's Nix daemon drives as a remote
builder.

1. **Install Nix on the Mac** (it isn't installed by default). The Determinate
   Systems installer sets up the daemon + flakes cleanly:

   ```sh
   curl --proto '=https' --tlsv1.2 -sSf -L https://install.determinate.systems/nix | sh -s -- install
   ```

2. **Start the builder VM** and register it:

   ```sh
   nix run nixpkgs#darwin.linux-builder
   ```

   It boots a minimal `aarch64-linux` NixOS VM and prints a `builders = ...` line
   to add to `/etc/nix/nix.conf` on the Mac, e.g.:

   ```
   builders = ssh://builder@linux-builder aarch64-linux /etc/nix/builder_ed25519 - - - -
   builders-use-substitutes = true
   ```

   (If you run **nix-darwin**, prefer `nix.linux-builder.enable = true;` — it
   manages the VM as a launchd service declaratively.)

3. From then on, run the `nix build` / `nixos-rebuild` commands below **on the
   Mac**. Nix offloads the aarch64 compilation to the VM automatically and ships
   the result to the Pi.

> Apple Silicon only — an Intel Mac VM would be x86_64 and couldn't build
> aarch64 without emulation. Alternatively, skip the VM and add
> `--build-host z@hopper.internal` to build on the Pi itself (slower).

---

## 1. Build and flash the bootstrap image

raspberry-pi-nix produces a bootable disk image from the flake.

```sh
nix build .#nixosConfigurations.hopper.config.system.build.sdImage
```

The image lands in `./result/sd-image/*.img.zst`. Flash it to the **USB SSD**
(preferred over the SD card — rebuilds chew through SD cards):

```sh
zstdcat result/sd-image/*.img.zst | sudo dd of=/dev/disk/<SSD> bs=4M status=progress conv=fsync
```

Replace `/dev/disk/<SSD>` with the real device (`lsblk` / `diskutil list`).
**Double-check the device** — `dd` to the wrong disk is unrecoverable.

Set the Pi 4 to boot USB-first (EEPROM `BOOT_ORDER=0xf41`) per the notes in
[configuration.nix](configuration.nix), then connect it to the network core and
power it on.

## 2. First boot and networking

- hopper comes up via DHCP. Add a **DHCP reservation** on the GL.iNet router so
  its IP is stable, and point `hopper.internal` at it (or rely on mDNS).
- Confirm SSH works:

  ```sh
  ssh z@hopper.internal
  ```

  (Your key from `common.nix` is already authorized.)

## 3. Enrol hopper's sops key

Secrets are encrypted to hopper's SSH host key (as an age key), which only
exists after first boot. On hopper:

```sh
ssh-to-age < /etc/ssh/ssh_host_ed25519_key.pub
```

Then, in this repo:

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

## 3b. Cloudflare DNS records (for TLS certs)

Traefik requests a **Let's Encrypt wildcard cert** for `hopper.zjones.dev` via
the Cloudflare DNS-01 challenge. The challenge only needs DNS-edit permission on
the zone — the host does **not** need to be publicly reachable — but the A
records must exist so clients can resolve the names to hopper's private IP.

In the Cloudflare dashboard for `zjones.dev`, add (DNS-only / grey-cloud, **not**
proxied):

| Type | Name                  | Content                        |
|------|-----------------------|--------------------------------|
| A    | `hopper`              | hopper's LAN or Tailscale IP   |
| A    | `*.hopper`            | hopper's LAN or Tailscale IP   |

> The wildcard `*.hopper` covers `adguard.hopper.zjones.dev`, `beszel...`, etc.
> Pointing these at a private/tailnet IP is intentional — services stay off the
> public internet while still getting valid certs.

## 4. Deploy

From a build host that can produce aarch64 derivations:

```sh
nixos-rebuild switch \
  --flake .#hopper \
  --target-host z@hopper.internal \
  --use-remote-sudo
```

- `--target-host` ships the closure to hopper and activates it there.
- Add `--build-host z@hopper.internal` to build *on the Pi* instead of locally.
- Use `boot` instead of `switch` if a change needs a reboot (firmware/kernel);
  use `test` for a no-bootloader trial run.

Locally on hopper you can also use the `nrs` / `nrt` aliases from
[home.nix](home.nix).

## 5. Post-deploy checklist

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

After the bootstrap, every later change is just:

```sh
git pull          # on the build host
nixos-rebuild switch --flake .#hopper --target-host z@hopper.internal --use-remote-sudo
```

No reflashing — that's only for the initial install or a corrupted disk.
