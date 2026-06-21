#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# hopper — Raspberry Pi OS Lite (64-bit, Bookworm) host bootstrap
# ─────────────────────────────────────────────────────────────────────────────
# This is the ONE-TIME OS-level setup for hopper. It does NOT install the
# application services — those live in the homelab_stacks repo as Docker
# Compose (see HOMELAB_STACKS_HANDOFF.md). This script gets the box to the
# point where `docker compose up` works and the node is on the tailnet.
#
# Assumes hostname / user `z` / SSH pubkey were set in Raspberry Pi Imager's
# advanced options before flashing, so the box is already reachable over SSH.
#
# Usage (run on hopper):
#   TS_AUTHKEY=tskey-auth-xxxx sudo -E bash bootstrap.sh
#
# Idempotent: safe to re-run. Secrets are passed via env, never written here.
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "Run with sudo: TS_AUTHKEY=... sudo -E bash bootstrap.sh" >&2
  exit 1
fi

TARGET_USER="${SUDO_USER:-z}"

echo "==> [1/6] System update"
apt-get update
apt-get -y full-upgrade

echo "==> [2/6] Docker (rootful) via get.docker.com"
# Rootful Docker is a deliberate choice for this LAN appliance: it makes the
# homelab_stacks compose files plain-vanilla (no port-binding sysctls, no
# user-lingering, docker.sock at the standard path). Tighten to rootless later
# if you want, but it's not worth the friction on a box that isn't exposed.
if ! command -v docker >/dev/null 2>&1; then
  curl -fsSL https://get.docker.com | sh
fi
usermod -aG docker "$TARGET_USER"
systemctl enable --now docker

echo "==> [3/6] Free port 53 for AdGuard Home"
# AdGuard Home (a container in homelab_stacks) must own :53 on the LAN. Bookworm
# Lite normally doesn't run systemd-resolved, but disable its stub listener if
# present so nothing squats on 53. The Pi resolves via 127.0.0.1 once AdGuard
# is up; until then, fall back to a public resolver so apt/curl keep working.
if systemctl is-enabled systemd-resolved >/dev/null 2>&1; then
  mkdir -p /etc/systemd/resolved.conf.d
  cat > /etc/systemd/resolved.conf.d/no-stub.conf <<'EOF'
[Resolve]
DNSStubListener=no
EOF
  systemctl restart systemd-resolved || true
fi
# Pin a working upstream for the host itself during bring-up. After AdGuard is
# running you can point this at 127.0.0.1.
if ! grep -q '1.1.1.1' /etc/resolv.conf 2>/dev/null; then
  echo "    (leaving /etc/resolv.conf as-is; set to 127.0.0.1 after AdGuard is up)"
fi

echo "==> [4/6] Tailscale (exit node)"
if ! command -v tailscale >/dev/null 2>&1; then
  curl -fsSL https://tailscale.com/install.sh | sh
fi
if [[ -n "${TS_AUTHKEY:-}" ]]; then
  # --accept-dns=false: this box IS the DNS server; never let Tailscale
  # overwrite its resolver. Approve the exit node in the admin console after.
  tailscale up \
    --authkey="${TS_AUTHKEY}" \
    --hostname=hopper \
    --advertise-exit-node \
    --accept-dns=false \
    --ssh
  echo "    Approve the exit node: admin console → Machines → hopper → Edit route settings"
else
  echo "    TS_AUTHKEY not set — skipping. Run later:"
  echo "    sudo tailscale up --advertise-exit-node --accept-dns=false --ssh"
fi

echo "==> [5/6] Harden SSH (key-only)"
# Imager enables SSH but leaves password auth on. Lock it down.
install -d -m 0755 /etc/ssh/sshd_config.d
cat > /etc/ssh/sshd_config.d/99-hardening.conf <<'EOF'
PasswordAuthentication no
PermitRootLogin no
EOF
systemctl restart ssh

echo "==> [6/6] Headless tweaks"
# Minimal GPU split on a headless box; harmless if already set.
CONFIG_TXT=/boot/firmware/config.txt
if [[ -f "$CONFIG_TXT" ]] && ! grep -q '^gpu_mem=16' "$CONFIG_TXT"; then
  echo 'gpu_mem=16' >> "$CONFIG_TXT"
fi

cat <<'DONE'

──────────────────────────────────────────────────────────────────────────────
hopper OS bootstrap complete.

Next:
  1. NUT (UPS monitoring) is NOT in Docker — it needs USB + shutdown control.
     See the "Appendix: NUT" section in hosts/README-rpi-os.md.
  2. Deploy the application services from the homelab_stacks repo:
     clone it, drop the .env secrets in place, then `docker compose up -d`.
     See HOMELAB_STACKS_HANDOFF.md for the full layout.
  3. Once AdGuard is serving, set the Pi's own resolver to 127.0.0.1 and
     add hopper as the primary DNS in the GL.iNet DHCP settings.
──────────────────────────────────────────────────────────────────────────────
DONE
