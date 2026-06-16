# Deploying pi3 (Raspberry Pi 3 — backup DNS)

> **Placeholder name.** This host is scaffolded as `pi3`; rename it (hostname,
> flake output, `secrets/pi3.yaml`, `.sops.yaml` regex, the `nrs`/`nrt` aliases)
> once the real unit is in hand. The commands below use `pi3`.

pi3 is an `aarch64-linux` host built from nixos-hardware's `raspberry-pi-3`
profile plus nixpkgs' `sd-image-aarch64` module — **not** raspberry-pi-nix,
which doesn't support the Pi 3. It runs only AdGuard Home + Unbound (a backup
resolver) and a Tailscale client. The flow mirrors hopper: flash once to
bootstrap → enrol its sops key → deploy with `nixos-rebuild --target-host`.

> **Build host note:** pi3 is `aarch64-linux`. A macOS workstation can't build it
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

> A Pi 3 is very slow to build on itself, so `--build-host z@pi3.internal` works
> but the Mac builder VM is much more pleasant here.

---

## 1. Build and flash the bootstrap image

The Pi 3 boots from **SD card** (USB boot is unreliable on this board):

```sh
nix build .#nixosConfigurations.pi3.config.system.build.sdImage
```

The image lands in `./result/sd-image/*.img.zst`. Flash it to the SD card:

```sh
zstdcat result/sd-image/*.img.zst | sudo dd of=/dev/disk/<SD> bs=4M status=progress conv=fsync
```

Replace `/dev/disk/<SD>` with the real device (`lsblk` / `diskutil list`).
**Double-check the device** — `dd` to the wrong disk is unrecoverable.

Insert the card, connect to the network, and power on.

## 2. First boot and networking

- pi3 comes up via DHCP. Add a **DHCP reservation** on the GL.iNet router so its
  IP is stable.
- Confirm SSH works (your key from `common.nix` is already authorized):

  ```sh
  ssh z@pi3.internal
  ```

## 3. Enrol pi3's sops key

Secrets are encrypted to pi3's SSH host key (as an age key), which only exists
after first boot. On pi3:

```sh
ssh-to-age < /etc/ssh/ssh_host_ed25519_key.pub
```

Then, in this repo:

1. Paste that pubkey into [`.sops.yaml`](../../.sops.yaml), replacing the
   `&pi3` placeholder.
2. Create the real encrypted secrets file (replaces the plaintext placeholder):

   ```sh
   sops secrets/pi3.yaml
   ```

   pi3 needs only one secret:
   - `tailscale/authKey` — reusable/ephemeral key from the Tailscale admin console

3. If you edited keys after creating the file: `sops updatekeys secrets/pi3.yaml`

## 4. Deploy

From a build host that can produce aarch64 derivations:

```sh
nixos-rebuild switch \
  --flake .#pi3 \
  --target-host z@pi3.internal \
  --use-remote-sudo
```

- Add `--build-host z@pi3.internal` to build *on the Pi* instead of locally
  (slow on a Pi 3 — a remote/local aarch64 builder is friendlier).
- Use `boot` instead of `switch` if a change needs a reboot.

Locally on pi3 you can also use the `nrs` / `nrt` aliases from
[home.nix](home.nix).

## 5. Post-deploy checklist

- **Tailscale:** plain client (not an exit node) — no admin-console approval
  needed. Confirm it joined the tailnet: `tailscale status`.
- **DNS failover:** in the GL.iNet DHCP settings, set pi3 as the **secondary**
  DNS server (primary = hopper). That's the entire failover mechanism. Verify
  pi3 resolves on its own:

  ```sh
  dig @pi3.internal example.com
  ```

- **AdGuard UI:** `dns.nix` binds the web UI to localhost and there's no Traefik
  on this box. Reach it over the tailnet via an SSH tunnel:

  ```sh
  ssh -L 3000:127.0.0.1:3000 z@pi3.internal   # then open http://localhost:3000
  ```

  (Or set `services.adguardhome.host` to the tailnet IP if you want it bound
  directly.) Config is declarative (`mutableSettings = false`), so the UI is
  effectively read-only for settings — mirror hopper's filter lists in
  `dns.nix` rather than editing in the UI.

## Routine updates

```sh
git pull          # on the build host
nixos-rebuild switch --flake .#pi3 --target-host z@pi3.internal --use-remote-sudo
```

No reflashing — that's only for the initial install or a corrupted card.
