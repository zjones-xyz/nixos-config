# Check that the ProtonVPN tunnel is still carrying traffic.
#
# Run every 60s by systemd.timers.protonvpn-healthcheck
# (hosts/galactica/nixflix.nix), as root on the host — `wg show` is a netlink
# query needing CAP_NET_ADMIN, which a DynamicUser inside the namespace lacks,
# so this reaches in with `ip netns exec` instead of being confined.
#
# The module supplies:
#   NETNS       the vpn-confinement namespace name.
#   WG_IFACE    the WireGuard interface inside it.
#   GATEWAY     Proton's gateway, pinged only to generate traffic.
#   MAX_AGE     handshake age, in seconds, past which the tunnel is dead.
#
# Exit non-zero — a failed unit visible in `systemctl --failed` — is the alarm.
# `set -euo pipefail` comes from writeShellApplication.

# Distinguish "namespace never came up" from "tunnel went quiet" — the two have
# different fixes, and the handshake test below cannot tell them apart. `ip
# netns` reads exactly this directory, so testing it directly beats spawning
# `ip netns list | grep`.
if [ ! -e "/run/netns/$NETNS" ]; then
  echo "protonvpn: the $NETNS namespace does not exist — check wg.service" >&2
  exit 1
fi

# One peer, but take the newest defensively rather than assuming. Done entirely
# in awk rather than `sort -rn | head -n1`: under `set -e` with `pipefail`, a
# `head` that closes the pipe early can SIGPIPE its producer and kill the check
# with no message of its own. `|| hs=""` catches the remaining case — the
# namespace exists but the interface does not — so the branch below reports it.
handshake_age() {
  local hs
  hs=$(ip netns exec "$NETNS" wg show "$WG_IFACE" latest-handshakes \
    | awk '{ if ($2 > m) m = $2 } END { print m + 0 }') || hs=""
  [ -n "$hs" ] && [ "$hs" -ne 0 ] || return 1
  # $EPOCHSECONDS rather than $(date +%s) — bash builtin, no process.
  echo $(( EPOCHSECONDS - hs ))
}

# Cheap path first. A healthy tunnel answers here with no ping and no waiting:
# the sidecar's NAT-PMP renewals already keep traffic flowing every 45s, so the
# handshake is normally far fresher than MAX_AGE. Probing unconditionally would
# park this unit for 2-5s of every 60s to re-learn something `wg show` just
# told us for free.
if age=$(handshake_age) && [ "$age" -le "$MAX_AGE" ]; then
  echo "protonvpn: tunnel healthy (last handshake ${age}s ago)"
  exit 0
fi

# Stale or never-handshaken. Before believing it, force a packet into the
# tunnel: WireGuard only rekeys when it has something to send, so a genuinely
# idle tunnel — the sidecar stopped, say — can look dead while being fine.
# Proton's gateway is not guaranteed to answer ICMP, so the ping's exit status
# is deliberately ignored; it exists to provoke the rekey, not to prove
# reachability. Then re-read, bounded, rather than sleeping a fixed interval.
ip netns exec "$NETNS" ping -c 1 -W 3 "$GATEWAY" >/dev/null 2>&1 || true

for _ in 1 2 3; do
  if age=$(handshake_age) && [ "$age" -le "$MAX_AGE" ]; then
    echo "protonvpn: tunnel healthy (last handshake ${age}s ago, after rekey)"
    exit 0
  fi
  sleep 1
done

if age=$(handshake_age); then
  echo "protonvpn: last $WG_IFACE handshake was ${age}s ago (>${MAX_AGE}s) — tunnel is down" >&2
else
  echo "protonvpn: $WG_IFACE has never completed a handshake — tunnel is down" >&2
fi
exit 1
