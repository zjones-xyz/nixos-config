# Deploying hopper (Raspberry Pi 4)

hopper is an `aarch64-linux` host built with `raspberry-pi-nix`. The flow is:
build a complete SD image on **memory-alpha** (which emulates aarch64 via
binfmt) → flash it → boot straight into the full hopper config → enrol its
sops key → deploy normally with `nixos-rebuild --target-host` from then on.

---

## 0. Build host: memory-alpha (not the Mac)

> **macOS 26 (Darwin 25.x) known issue:** The `darwin.linux-builder` VM crashes
> immediately on macOS 26 due to a QEMU / Hypervisor.framework incompatibility
> (`HVF SMCR_EL1 assertion failed`). This affects both nixpkgs and
> nixpkgs-unstable as of June 2026.
>
> **memory-alpha is the aarch64 build host instead.** It registers QEMU
> user-mode emulation via `boot.binfmt.emulatedSystems = [ "aarch64-linux" ]`
> (see its `configuration.nix`), so it can build aarch64 closures and images
> natively-ish. Emulated builds are slower than native but far faster than a
> Pi 4, and they spare the Pi's SD card the compile churn.
>
> We also tried `nixos-anywhere`, but it requires `kexec` on the target and the
> Raspberry Pi OS kernel ships without `CONFIG_KEXEC`, so that path is dead for
> a Pi-OS carrier. Building the image directly sidesteps it entirely.

---

## 1. Bootstrap: build and flash the hopper SD image

### 1a. Build the image on memory-alpha

SSH into memory-alpha, clone this repo, and build hopper's SD image. Because
memory-alpha has aarch64 binfmt emulation, this just works:

```sh
ssh z@memory-alpha.internal
nix-shell -p git    # if git isn't already available
git clone <your-nixos-config-repo-url> ~/nixos-config
cd ~/nixos-config
nix build .#nixosConfigurations.hopper.config.system.build.sdImage
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

This image *is* the full hopper config — there's no separate "switch to the
real config" step. Insert the card, connect hopper to the network, power it on.

1. Add a **DHCP reservation** on the GL.iNet router so hopper's IP is stable,
   and point `hopper.internal` at it (or rely on mDNS).
2. Confirm SSH works (your key is baked in via `common.nix`):

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
Traefik, NUT, Beszel, speedtest-tracker) come up properly. From the Mac, with
memory-alpha as the aarch64 build host:

```sh
nixos-rebuild switch \
  --flake .#hopper \
  --target-host z@hopper.internal \
  --build-host z@memory-alpha.internal \
  --use-remote-sudo
```

`--build-host z@memory-alpha.internal` offloads the aarch64 build to
memory-alpha and ships the closure to hopper — no Mac builder needed, and the
Pi never compiles. This is the standard command for all subsequent deploys.

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

All hosts default to the **Let's Encrypt staging CA** via the shared
`homelab.letsencryptStaging` flag (declared in
[`modules/nixos/letsencrypt.nix`](../../modules/nixos/letsencrypt.nix)), so
debugging can't burn the strict production rate limits. Staging certs are
issued by an untrusted root, so browsers will warn — that's expected. Use this
phase to confirm the DNS challenge succeeds (check `docker logs traefik` for
"certificate obtained").

Once certs are issuing cleanly, flip to production by setting the flag to
`false` — per host in its `configuration.nix`, or once in
[`modules/nixos/common.nix`](../../modules/nixos/common.nix) to switch every
host:

```nix
homelab.letsencryptStaging = false;
```

Then redeploy. Staging and production certs use **separate** `acme.json` files
(`acme-staging.json` vs `acme.json`), so no manual cert deletion is needed —
Traefik just requests fresh production certs into the production file on
startup. Flipping back to staging reuses the cached staging certs.

## Routine updates

From the Mac, once hopper is running:

```sh
git pull
nixos-rebuild switch \
  --flake .#hopper \
  --target-host z@hopper.internal \
  --build-host z@memory-alpha.internal \
  --use-remote-sudo
```

No reflashing — that's only for the initial install or a corrupted card.
