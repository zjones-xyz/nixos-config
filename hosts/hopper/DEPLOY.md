# Deploying hopper (Raspberry Pi 4)

hopper is an `aarch64-linux` host built with `raspberry-pi-nix`. The flow is:
flash an image once to bootstrap → enrol its sops key → deploy normally with
`nixos-rebuild --target-host` from then on.

> **Build host note:** hopper is `aarch64-linux`. A macOS workstation can't build
> it natively. Build on an aarch64 Linux machine (the Pi itself, or another
> arm64 box), or configure an aarch64 remote builder / binfmt emulation. The
> commands below assume you run them somewhere that can produce aarch64
> derivations.

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
   - `tailscale/authKey` — reusable/ephemeral key from the Tailscale admin console
   - `nut/upsmonPassword` — any password; matches the upsd user
   - `beszel/agentKey` — `KEY=ssh-ed25519 ...`, the Beszel hub's public key
   - `speedtest-tracker/appKey` — `APP_KEY=base64:...` (`openssl rand -base64 32`)

3. If you edited keys after creating the file: `sops updatekeys secrets/hopper.yaml`

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
  settings (pi3 secondary, once it exists). Verify:

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
- **Web UIs:** reachable at `*.hopper.internal` via Traefik (self-signed TLS) —
  `traefik`, `adguard`, `kuma`, `ntfy`, `beszel`, `speedtest`, and Homepage at
  the root `hopper.internal`.

## Routine updates

After the bootstrap, every later change is just:

```sh
git pull          # on the build host
nixos-rebuild switch --flake .#hopper --target-host z@hopper.internal --use-remote-sudo
```

No reflashing — that's only for the initial install or a corrupted disk.
