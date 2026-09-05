# Renew ProtonVPN's NAT-PMP forward and publish the port to qBittorrent.
#
# Run by systemd.services.protonvpn-natpmp (hosts/galactica/nixflix.nix), inside
# the `wg` network namespace. That module supplies everything host-specific:
#
#   QB_URL   qBittorrent's WebUI base URL. NOT loopback — when confined,
#            nixflix binds the WebUI to the namespace address, so this is
#            derived from the module's own `connectionAddress`.
#   QB_USER  WebUI username.
#   GATEWAY  Proton's WireGuard gateway, which answers NAT-PMP.
#   $CREDENTIALS_DIRECTORY/qbPassword  the WebUI password, via LoadCredential.
#
# `set -euo pipefail` comes from writeShellApplication.

QB_PASS="$(cat "$CREDENTIALS_DIRECTORY/qbPassword")"

published=""

# Backoff for the failure paths below. A Proton outage does not stop this loop
# — natpmpc simply fails against a black-holed gateway forever — so a fixed 10s
# retry writes ~6 journal lines a minute for the whole outage (~8.6k a day) onto
# midden. Doubling to a 5-minute ceiling keeps a short blip responsive while a
# long one costs ~12 lines an hour. Reset to the floor on every success so a
# recovered tunnel is picked up at full speed.
backoff_min=10
backoff_max=300
backoff=$backoff_min

# Log, wait out the current backoff, then double it up to the ceiling. Both
# failure paths below use this rather than repeating the doubling arithmetic.
retry() {
  echo "$1; retrying in ${backoff}s" >&2
  sleep "$backoff"
  backoff=$(( backoff * 2 > backoff_max ? backoff_max : backoff * 2 ))
}

while :; do
  # Both protocols must be mapped and renewed; the TCP reply carries the port
  # we hand to qBittorrent. Proton grants the same number for both.
  natpmpc -a 1 0 udp 60 -g "$GATEWAY" >/dev/null 2>&1 || true

  if ! reply=$(natpmpc -a 1 0 tcp 60 -g "$GATEWAY" 2>&1); then
    retry "natpmpc failed (tunnel down or still coming up?)"
    continue
  fi

  # Bash's own regex rather than `sed … | head -n1`: under the
  # `set -euo pipefail` writeShellApplication supplies, a `head` that closes
  # the pipe early can SIGPIPE its producer and kill this loop with no message.
  # The sibling healthcheck avoids the same shape for the same reason. This
  # also spawns nothing, and takes the first match for free.
  port=""
  [[ $reply =~ Mapped\ public\ port\ ([0-9]+) ]] && port=${BASH_REMATCH[1]}

  if [ -z "$port" ]; then
    retry "no port in natpmpc reply"
    continue
  fi

  # natpmpc answered with a usable port, so the tunnel is carrying traffic
  # again — drop straight back to the fast retry.
  backoff=$backoff_min

  # Only talk to qBittorrent when the port actually changed — this loop runs
  # every 45s and the port is usually stable for days.
  if [ "$port" != "$published" ]; then
    jar=$(mktemp)
    if curl -sf -c "$jar" \
         --data-urlencode "username=$QB_USER" \
         --data-urlencode "password=$QB_PASS" \
         "$QB_URL/api/v2/auth/login" >/dev/null \
       && curl -sf -b "$jar" \
            --data-urlencode "json={\"listen_port\":$port}" \
            "$QB_URL/api/v2/app/setPreferences" >/dev/null; then
      echo "published forwarded port $port to qBittorrent"
      published="$port"
    else
      echo "failed to publish port $port to qBittorrent; will retry" >&2
    fi
    rm -f "$jar"
  fi

  # Lease is 60s; renew with headroom.
  sleep 45
done
