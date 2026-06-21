# Raspberry Pi hosts — Raspberry Pi OS Lite

hopper (Pi 4) and hamilton (Pi 3) run **Raspberry Pi OS Lite (64-bit, Trixie)**,
not NixOS. After fighting uncached kernel builds and a non-booting SD image, the
NixOS-on-Pi route was abandoned for these two boxes. memory-alpha stays on NixOS.

The split:

| Layer | Where it lives | What |
|-------|----------------|------|
| OS bring-up | `bootstrap.sh` in this repo | Docker, Tailscale, SSH hardening, freeing :53, (hopper) NUT |
| Application services | **homelab_stacks** repo (Docker Compose) | Traefik, AdGuard, Unbound, Homepage, Beszel, Uptime Kuma, ntfy, Speedtest Tracker |

The old NixOS modules (`modules/nixos/*.nix`) and flake entries for hopper/hamilton
are now dead for these hosts — kept for reference and as the source of truth for
ports/domains/config that the Compose stacks reproduce. Clean them out of the
flake once the Pis are confirmed stable (follow-up, not urgent).

## Flashing

Use **Raspberry Pi Imager** → Raspberry Pi OS Lite (64-bit). In the gear/advanced
options set **before** writing:

- Hostname: `hopper` / `hamilton`
- Username: `z`, and paste the SSH public key (disable password login)
- Enable SSH (public-key only)
- Locale / timezone: `America/Los_Angeles`
- Wi-Fi if not on Ethernet

This is the entire pre-flash config — no `dietpi.txt`-style file to hand-edit.

## Boot medium

- **hamilton (Pi 3):** boot from microSD. Pi 3 USB boot is unreliable, and as a
  backup resolver it rebuilds rarely, so SD wear isn't a real concern.
- **hopper (Pi 4):** boot from a **USB SSD** (USB-SATA adapter), not microSD.
  hopper writes constantly — AdGuard query data, Beszel metrics, Speedtest
  history, container layers, logs — which is exactly what wears out SD cards.
  An SSD shrugs it off.

### Booting hopper from a USB SSD

1. Flash RPi OS Lite **directly to the SSD** over the adapter with Imager (same
   advanced-options config above). Boot with the SSD plugged in and no microSD.
2. **If it doesn't boot,** the Pi 4 EEPROM may predate USB boot support. Boot a
   microSD once, then:
   ```sh
   sudo rpi-eeprom-update -a       # update bootloader firmware
   sudo raspi-config                # Advanced → Boot Order → USB Boot
   ```
   Reboot onto the SSD.
3. **Port speed:** this Pi 4's USB3 port is physically bent (mechanical, not
   dead). Try the USB3 port — gently seat the adapter — and confirm the link
   rate:
   ```sh
   lsusb -t      # 5000M = USB3 (~200-300 MB/s); 480M = negotiated down to USB2 (~40 MB/s)
   ```
   USB2 still vastly outperforms microSD for random I/O and reliability, so
   either result is fine for this workload — USB3 is just gravy.
4. **If the SSD hangs or drops under load,** the adapter's UAS mode may be
   buggy on the Pi. Find the adapter's USB ID (`lsusb`) and disable UAS by
   appending to `/boot/firmware/cmdline.txt` (one line, space-separated):
   `usb-storage.quirks=AAAA:BBBB:u` (replace `AAAA:BBBB` with the ID). Reboot.

## Bootstrap

SSH in, copy the script over (or `curl` it from the repo), and run:

```sh
# hopper
TS_AUTHKEY=tskey-auth-xxxx sudo -E bash bootstrap.sh

# hamilton
TS_AUTHKEY=tskey-auth-xxxx sudo -E bash bootstrap.sh
```

Generate the Tailscale auth key in the admin console (reusable + ephemeral is
fine). It's the only secret the bootstrap needs.

After bootstrap, deploy the services from **homelab_stacks** — see
[`HOMELAB_STACKS_HANDOFF.md`](../HOMELAB_STACKS_HANDOFF.md).

## DNS chain

Both Pis run the same resolver chain (containers, in homelab_stacks):

```
LAN client → AdGuard Home :53 → Unbound :5335 (recursive, container-internal)
```

GL.iNet DHCP is the source of truth for IPs and DNS hand-out:
- **hopper** = primary DNS
- **hamilton** = secondary DNS

That router-level secondary is the whole failover story — if hopper is down,
clients fall through to hamilton.

---

## Appendix: Encrypting service data at rest (hopper)

Goal: keep the sensitive persistent data — ntfy's message/auth db, Beszel's
metrics, and container logs that Dozzle surfaces — on a LUKS volume, so a stolen
or discarded SSD reveals nothing. LUKS only protects data **at rest**; while
hopper runs and the volume is unlocked, the data is readable. It does nothing
against a compromise of the live box.

**What holds the data:**
- ntfy → its cache/message db + (if auth enabled) user db. Most sensitive.
- Beszel → hub data dir (metrics history).
- Dozzle → ~nothing of its own; the *logs it displays* live in Docker's
  data-root (`/var/lib/docker/containers/*/*-json.log`). To encrypt logs at
  rest you must put **Docker's data-root** on LUKS, not Dozzle's volume.

**The DNS tension (read this first):** hopper is the primary DNS. If unlocking
is manual, Docker — and therefore AdGuard/Unbound — won't start after a reboot
until you SSH in and type the passphrase; LAN DNS rides on hamilton until then.
The two sketches below resolve this differently.

**Chosen approach: Option B — manual passphrase over SSH.** hopper reboots at
most once a month (security updates), so a manual unlock step is acceptable.
Root stays unencrypted so DNS self-recovers headless; only ntfy + Beszel data go
on the LUKS volume. The Tang/Clevis network-unlock option is documented above
the partition steps in git history if you want to revisit it later.

---

### Step 1 — Repartition (from microSD boot)

RPi OS auto-expanded root to fill the SSD. You can't shrink a mounted root
filesystem, so boot from the microSD with the SSD plugged in as a data disk.

```sh
# Confirm layout — sda1=boot(FAT), sda2=root(ext4, ~119GB)
sudo parted /dev/sda print

# Shrink filesystem FIRST (always shrink fs before partition)
sudo e2fsck -f /dev/sda2
sudo resize2fs /dev/sda2 75G          # target ~75G, leaving margin

# Shrink the partition to match, then create the LUKS partition
sudo parted /dev/sda resizepart 2 79GB
sudo parted /dev/sda mkpart primary 79GB 100%

# Verify
sudo parted /dev/sda print
# Should show: sda1 ~512MB fat32, sda2 ~79GB ext4, sda3 ~40GB (new, unformatted)
```

> **Order matters:** `resize2fs` then `parted resizepart`. Never shrink the
> partition first — that would truncate the filesystem and corrupt data.

Boot back from the SSD before continuing.

---

### Step 2 — Format and configure LUKS (from SSD)

```sh
# Format the new partition as LUKS — choose a strong passphrase
sudo cryptsetup luksFormat /dev/sda3

# Open, format, and mount to verify
sudo cryptsetup luksOpen /dev/sda3 cryptdata
sudo mkfs.ext4 /dev/mapper/cryptdata
sudo mkdir -p /srv/secure
sudo mount /dev/mapper/cryptdata /srv/secure
sudo df -h /srv/secure    # should show ~40G available
```

---

### Step 3 — crypttab + fstab (noauto)

`/etc/crypttab` — `noauto` keeps this out of boot-time unlock:
```
cryptdata  /dev/sda3  none  noauto,luks
```

`/etc/fstab` — `noauto` keeps the mount manual too:
```
/dev/mapper/cryptdata  /srv/secure  ext4  noauto,nofail  0  2
```

---

### Step 4 — unlock script

`/home/z/unlock.sh` (chmod 700):
```sh
#!/usr/bin/env bash
# Unlock the encrypted data partition and start services that depend on it.
# Run this after any reboot: bash ~/unlock.sh
set -euo pipefail

sudo cryptsetup luksOpen /dev/sda3 cryptdata
sudo mount /dev/mapper/cryptdata /srv/secure
sudo chown -R z:z /srv/secure

# Start only the services whose data lives on /srv/secure.
# AdGuard/Unbound/Traefik are already up from boot — don't restart them.
docker compose -f ~/homelab_stacks/hopper/docker-compose.yml \
  up -d ntfy beszel beszel-agent
echo "Unlocked and services started."
```

After a reboot, DNS and Traefik come up automatically. SSH in, run
`bash ~/unlock.sh`, and ntfy + Beszel are live within seconds.

---

### Step 5 — homelab_stacks volume paths

In the hopper compose file, point ntfy and Beszel at `/srv/secure`:
```yaml
# ntfy
volumes:
  - /srv/secure/ntfy/cache:/var/cache/ntfy
  - /srv/secure/ntfy/lib:/var/lib/ntfy

# beszel hub
volumes:
  - /srv/secure/beszel:/beszel_data
```

Everything else (AdGuard, Unbound, Traefik, Uptime Kuma, Homepage, Speedtest)
stays under `/home/z/` on the unencrypted root — these are fine plaintext and
must be available before you unlock.

---

## Appendix: NUT (hopper only)

The UPS monitoring stays **native on hopper**, not in Docker, for two reasons:
it needs USB device access to the UPS, and it must be able to shut the host
down cleanly on a low-battery event — both awkward/fragile in a container.

```sh
sudo apt-get install -y nut

# 1. Discover the UPS (it's on USB). Most consumer units use usbhid-ups.
sudo nut-scanner -U
```

Then write the config (paths under `/etc/nut/`):

`/etc/nut/ups.conf`
```ini
[cyberpower]
    driver = usbhid-ups
    port = auto
    desc = "Core rack UPS (modem/router/switch/hopper)"
```

`/etc/nut/upsd.conf` — listen on localhost only:
```ini
LISTEN 127.0.0.1 3493
```

`/etc/nut/upsd.users`
```ini
[upsmon]
    password = CHANGEME
    upsmon primary
```

`/etc/nut/upsmon.conf`
```ini
MONITOR cyberpower@localhost 1 upsmon CHANGEME primary
NOTIFYCMD /usr/sbin/upssched
NOTIFYFLAG ONBATT  SYSLOG+EXEC
NOTIFYFLAG ONLINE  SYSLOG+EXEC
NOTIFYFLAG LOWBATT SYSLOG+EXEC
NOTIFYFLAG COMMBAD SYSLOG+EXEC
NOTIFYFLAG COMMOK  SYSLOG+EXEC
```

`/etc/nut/upssched.conf` — route events to the ntfy container on localhost:
```ini
CMDSCRIPT /etc/nut/ups-notify.sh
PIPEFN /run/nut/upssched.pipe
LOCKFN /run/nut/upssched.lock
AT ONBATT  * EXECUTE onbattery
AT ONLINE  * EXECUTE online
AT LOWBATT * EXECUTE lowbattery
AT COMMBAD * EXECUTE commbad
AT COMMOK  * EXECUTE commok
```

`/etc/nut/ups-notify.sh` (chmod +x) — posts to the ntfy container's published
port on localhost. This works because ntfy publishes `127.0.0.1:2586`:
```sh
#!/usr/bin/env bash
event="$1"
case "$event" in
  onbattery)  title="UPS on battery";   prio="high";    tags="warning,battery" ;;
  online)     title="UPS power restored"; prio="default"; tags="white_check_mark" ;;
  lowbattery) title="UPS LOW battery";    prio="urgent";  tags="rotating_light" ;;
  commbad)    title="UPS comms lost";     prio="high";    tags="warning" ;;
  commok)     title="UPS comms restored"; prio="default"; tags="white_check_mark" ;;
  *)          title="UPS event: $event";  prio="default"; tags="electric_plug" ;;
esac
curl -fsS -H "Title: $title" -H "Priority: $prio" -H "Tags: $tags" \
  -d "hopper UPS event: $event" http://127.0.0.1:2586/ups || true
```

Set mode and enable:
```sh
echo 'MODE=netserver' | sudo tee /etc/nut/nut.conf
sudo systemctl enable --now nut-server nut-monitor
```

(This mirrors the old NixOS `nut.nix` — same driver, same ntfy `ups` topic,
same NOTIFYFLAG set. Replace `CHANGEME` with a real password in both files.)
