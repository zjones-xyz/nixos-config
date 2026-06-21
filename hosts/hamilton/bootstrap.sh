#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# hamilton — Raspberry Pi OS Lite (64-bit, Trixie) host bootstrap
# ─────────────────────────────────────────────────────────────────────────────
# One-time OS-level setup for hamilton, the BACKUP DNS resolver (Pi 3). It runs
# a smaller stack than hopper: just Traefik + AdGuard Home + Unbound, all in
# Docker via the homelab_stacks repo. No UPS, no exit node — plain tailnet
# membership so the box is reachable remotely.
#
# Assumes hostname / user `z` / SSH pubkey were set in Raspberry Pi Imager's
# advanced options before flashing.
#
# Usage (run on hamilton):
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

echo "==> [1/5] System update"
apt-get update
apt-get -y full-upgrade

echo "==> [2/5] Docker (rootful) via get.docker.com"
if ! command -v docker >/dev/null 2>&1; then
  curl -fsSL https://get.docker.com | sh
fi
usermod -aG docker "$TARGET_USER"
systemctl enable --now docker

echo "==> [3/5] Free port 53 for AdGuard Home"
if systemctl is-enabled systemd-resolved >/dev/null 2>&1; then
  mkdir -p /etc/systemd/resolved.conf.d
  cat > /etc/systemd/resolved.conf.d/no-stub.conf <<'EOF'
[Resolve]
DNSStubListener=no
EOF
  systemctl restart systemd-resolved || true
fi

echo "==> [4/5] Tailscale (plain client — NOT an exit node)"
if ! command -v tailscale >/dev/null 2>&1; then
  curl -fsSL https://tailscale.com/install.sh | sh
fi
if [[ -n "${TS_AUTHKEY:-}" ]]; then
  tailscale up \
    --authkey="${TS_AUTHKEY}" \
    --hostname=hamilton \
    --accept-dns=false \
    --ssh
else
  echo "    TS_AUTHKEY not set — skipping. Run later:"
  echo "    sudo tailscale up --accept-dns=false --ssh"
fi

echo "==> [5/5] Harden SSH (key-only)"
install -d -m 0755 /etc/ssh/sshd_config.d
cat > /etc/ssh/sshd_config.d/99-hardening.conf <<'EOF'
PasswordAuthentication no
PermitRootLogin no
EOF
systemctl restart ssh

cat <<'DONE'

──────────────────────────────────────────────────────────────────────────────
hamilton OS bootstrap complete.

Next:
  1. Deploy the hamilton stack from homelab_stacks (Traefik + AdGuard + Unbound):
     clone it, drop the .env secrets in place, then `docker compose up -d`.
     See HOMELAB_STACKS_HANDOFF.md.
  2. Once AdGuard is serving, add hamilton as the SECONDARY DNS in the GL.iNet
     DHCP settings (primary = hopper). That's the whole failover story.
──────────────────────────────────────────────────────────────────────────────
DONE
