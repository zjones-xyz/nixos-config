#!/bin/bash
set -euo pipefail

if [ "${CLAUDE_CODE_REMOTE:-}" != "true" ]; then
  exit 0
fi

NIX_VERSION="2.28.4"

if ! command -v nix >/dev/null 2>&1 && [ ! -x /root/.nix-profile/bin/nix ]; then
  # Single-user install needs a non-root nixbld group member (the classic
  # installer refuses to run if root itself is in the build-users-group).
  getent group nixbld >/dev/null || groupadd -r nixbld
  id nixbld1 >/dev/null 2>&1 || useradd -r -g nixbld -G nixbld -d /var/empty -s /usr/sbin/nologin nixbld1

  curl -fsSL "https://releases.nixos.org/nix/nix-${NIX_VERSION}/install" -o /tmp/nix-install.sh
  # This repo uses flakes exclusively, so the installer's default channel
  # fetch (blocked by the network policy anyway) is unneeded; ignore its
  # failure by not treating installer's own non-zero exit as fatal here.
  sh /tmp/nix-install.sh --no-daemon --no-channel-add --yes
fi

export PATH="/root/.nix-profile/bin:$PATH"

mkdir -p /root/.config/nix
if ! grep -q "experimental-features" /root/.config/nix/nix.conf 2>/dev/null; then
  echo "experimental-features = nix-command flakes" >> /root/.config/nix/nix.conf
fi

echo 'export PATH="/root/.nix-profile/bin:$PATH"' >> "$CLAUDE_ENV_FILE"

nix --version
