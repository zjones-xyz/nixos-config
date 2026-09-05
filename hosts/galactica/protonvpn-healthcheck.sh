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
# different fixes, and the handshake test below cannot tell them apart.
if ! ip netns list | grep -qw "$NETNS"; then
  echo "protonvpn: the $NETNS namespace does not exist — check wg.service" >&2
  exit 1
fi

# Force one packet into the tunnel. WireGuard only rekeys when it has something
# to send, so without this an idle tunnel ages out and reads as dead. -W 3
# doubles as settling time for the handshake to land when the gateway does not
# reply — Proton's is not guaranteed to answer ICMP, which is exactly why the
# exit status here is ignored and the handshake below is the real signal.
ip netns exec "$NETNS" ping -c 1 -W 3 "$GATEWAY" >/dev/null 2>&1 || true
sleep 2

# One peer, but take the newest defensively rather than assuming. Done entirely
# in awk rather than `sort -rn | head -n1`: under `set -e` with `pipefail`, a
# `head` that closes the pipe early can SIGPIPE its producer and kill the check
# with no message of its own. `|| hs=""` catches the remaining case — the
# namespace exists but the interface does not — so the branch below reports it.
hs=$(ip netns exec "$NETNS" wg show "$WG_IFACE" latest-handshakes \
  | awk '{ if ($2 > m) m = $2 } END { print m + 0 }') || hs=""

if [ -z "$hs" ] || [ "$hs" -eq 0 ]; then
  echo "protonvpn: $WG_IFACE has never completed a handshake — tunnel is down" >&2
  exit 1
fi

age=$(( $(date +%s) - hs ))

if [ "$age" -gt "$MAX_AGE" ]; then
  echo "protonvpn: last $WG_IFACE handshake was ${age}s ago (>${MAX_AGE}s) — tunnel is down" >&2
  exit 1
fi

echo "protonvpn: tunnel healthy (last handshake ${age}s ago)"
