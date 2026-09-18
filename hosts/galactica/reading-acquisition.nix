{ config, pkgs, lib, ... }:

# ─────────────────────────────────────────────────────────────────────────────
# galactica — the reading stack's ACQUISITION half.
# ─────────────────────────────────────────────────────────────────────────────
# Chaptarr (ebooks + audiobooks), Shelfmark (on-demand search), Suwayomi
# (manga), plus the confined proxy and the second FlareSolverr that carry
# Shelfmark's egress. READING-STACK.md §5 is the spec; §5a and §5d hold the
# constraints this file's shape comes from. The library half (Grimmory,
# Audiobookshelf, BookBridge) is reading-library.nix.


let
  nixflix = config.nixflix;
  netns = "wg";

  # Primary group for everything here, as in bazarr.nix: what these services
  # write is then owned by `media` with nothing to fix up afterwards.
  mediaGroup = nixflix.globals.libraryOwner.group;

  # ── Paths ─────────────────────────────────────────────────────────────────
  # `tank/books` is its own dataset (§6), so every import across it is a copy —
  # deliberate, and cheap for books. Service state joins the rest of appdata on
  # the special vdev's mirror (DECISIONS.md §7).
  library = "/tank/books";
  appdata = "/tank/appdata";

  # ⚠ Must match reading-library.nix: it mounts `${library}/library` as
  # Grimmory's `/books`, so anything Grimmory should index lives INSIDE that
  # root, not beside it. Chaptarr's roots and Suwayomi's downloads go here.
  libraryRoot = "${library}/library";

  # ⚠ The one value this file shares with reading-library.nix and cannot
  # derive: Shelfmark delivers into Grimmory's watched bookdrop and stops (§5,
  # finding 3). It must equal the directory that file mounts as Grimmory's
  # `/bookdrop` — a SIBLING of the library root, so a half-imported drop is
  # never scanned as library content. On the array, not the appdata mirror:
  # ingest then moves within one dataset instead of copying across two.
  bookdropDir = "${library}/bookdrop";

  # Shelfmark's TMP_DIR. On the array beside the bookdrop — see the tmpfiles
  # entry for why not appdata.
  stagingDir = "${library}/staging";

  # Written by reading-media-gid.service below; read by both containers.
  gidEnvFile = "/run/reading/media-gid.env";

  # Applied to Suwayomi's dataDir and the parents of the module's own tmpfiles
  # rule — see that rule for why the parents have to be spelled out.
  suwayomiDir = {
    user = config.services.suwayomi-server.user;
    group = mediaGroup;
    mode = "0750";
  };

  # ── Ports ─────────────────────────────────────────────────────────────────
  # ⚠ Chaptarr is 8789, not Readarr's 8787 (§5b). Suwayomi takes its own
  # upstream default because the nixpkgs module's 8080 is SABnzbd's. The rest
  # clear 8989/8990/7878/8686/9696/8080/8282/4533/8191/6767/6768/3010/3011.
  chaptarrPort = 8789;
  shelfmarkPort = 8084;
  suwayomiPort = 4567;
  proxyPort = 8888;
  bypasserPort = 8192;

  # ── Addresses a container can actually dial ───────────────────────────────
  # ⚠ Inside a container 127.0.0.1 is the container, so every host-local
  # upstream is reached on galactica's LAN address (the same literal
  # configuration.nix's DNS rewrites use) with a per-interface firewall opening
  # below. The confined services answer on the namespace address instead.
  hostAddress = "192.168.8.190";
  nsAddress = config.vpnNamespaces.${netns}.namespaceAddress;

  # ⚠ NOT pinned anywhere today — this is Docker's default for `docker0`, which
  # is the bridge these containers land on. It is written here because the
  # namespace needs a route back to it (`accessibleFrom` below) and tinyproxy
  # needs it as an allow-list; verify it on the host and pin it in the Docker
  # daemon settings rather than trusting the default to hold.
  dockerBridgeSubnet = "172.17.0.0/16";

  prowlarrPort = nixflix.prowlarr.config.hostConfig.port;
  sabnzbdPort = nixflix.usenetClients.sabnzbd.settings.misc.port;

  # Same path inside the container as on the host, so neither service needs a
  # remote-path mapping to recognise what the download clients report.
  downloadsDir = nixflix.downloadsDir;
in
{
  # ── The `media` gid, resolved at unit-start time ───────────────────────────
  # ⚠ `config.users.groups.media.gid` is NULL at evaluation — two nixflix
  # modules mkForce the group to an empty set, wiping the gid it otherwise sets
  # (READING-STACK.md §4.7). The number does exist once the system is up, so
  # read it then and hand it over through an env file: `docker run --env-file`
  # reads that at start. Touches no live group, needs no nixflix patch, and
  # follows if the number ever moves.
  systemd.services.reading-media-gid = {
    description = "Resolve the ${mediaGroup} gid for the reading stack's containers";
    # reading-library.nix's Grimmory consumes the same file — it has to write
    # into the bookdrop, which Shelfmark chowns to shelfmark:media on start.
    wantedBy = [ "multi-user.target" ];

    serviceConfig = {
      Type = "oneshot";
      # The env file has to outlive the unit's exit, and RuntimeDirectory is
      # cleaned on stop without both of these.
      RemainAfterExit = true;
      RuntimeDirectory = "reading";
      RuntimeDirectoryPreserve = true;
    };

    script = ''
      gid=$(${pkgs.getent}/bin/getent group ${mediaGroup} | ${pkgs.coreutils}/bin/cut -d: -f3)
      # ⚠ Fail loudly rather than write an empty PGID: the entrypoints read that
      # as "use my default group", which is exactly the silent miswrite §4.7
      # exists to prevent.
      if [ -z "$gid" ]; then
        echo "group ${mediaGroup} exists with no gid — refusing to write an empty PGID" >&2
        exit 1
      fi
      # Both spellings: Chaptarr and Shelfmark read PGID, Grimmory reads
      # GROUP_ID, and an unused extra in an env file is inert.
      ${pkgs.coreutils}/bin/printf 'PGID=%s\nGROUP_ID=%s\n' "$gid" "$gid" \
        > /run/reading/media-gid.env
    '';
  };

  # ── Container identities ──────────────────────────────────────────────────
  # These accounts run nothing; they exist so `PUID`/`PGID` name a real owner
  # and the uid is reserved. Fixed ids above nixpkgs' static range (ids.nix
  # tops out at 327) and below the 999-and-descending dynamic allocation; a
  # collision is a loud eval error, never silent.
  users.users = {
    chaptarr = {
      isSystemUser = true;
      group = mediaGroup;
      uid = 400;
    };
    shelfmark = {
      isSystemUser = true;
      group = mediaGroup;
      uid = 401;
    };
  };

  # ── Directories ───────────────────────────────────────────────────────────
  # The datasets themselves are a manual step (MANUAL-STEPS.md); these are the
  # subdirectories inside them. Library trees are `root:media` 0775 like
  # nixflix's mediaDirs, so a umask of 002 is all any service needs.
  systemd.tmpfiles.settings."12-reading-acquisition" = {
    "${appdata}/chaptarr".d = {
      user = "chaptarr";
      group = mediaGroup;
      mode = "0755";
    };
    "${appdata}/shelfmark".d = {
      user = "shelfmark";
      group = mediaGroup;
      mode = "0755";
    };
    # Download staging, on the ARRAY. ⚠ Not Shelfmark's default
    # `/tmp/shelfmark` (the container overlay, i.e. the root NVMe), and not
    # under appdata either: that is the special vdev's SSD mirror, so multi-GB
    # transient staging would land on the latency-critical metadata device —
    # and delivery into the bookdrop would still cross datasets, the very copy
    # the bookdropDir binding avoids. Same dataset as the bookdrop, so it does
    # not.
    "${stagingDir}".d = {
      user = "shelfmark";
      group = mediaGroup;
      mode = "0775";
    };
    # ⚠ The two intermediate directories are not decoration. The module's own
    # rule is for `<dataDir>/.local/share/Tachidesk`; tmpfiles creates missing
    # parents as root, then refuses to descend from a user-owned directory into
    # a root-owned one ("unsafe path transition"), so Tachidesk is never made
    # and the unit dies in envsubst. Owning the chain keeps every step the same
    # uid. Only bites because dataDir is off /var/lib.
    "${appdata}/suwayomi".d = suwayomiDir;
    "${appdata}/suwayomi/.local".d = suwayomiDir;
    "${appdata}/suwayomi/.local/share".d = suwayomiDir;
    "${libraryRoot}/ebooks".d = {
      inherit (nixflix.globals.libraryOwner) user group;
      # ⚠ setgid, and tmpfiles is why it must be said: it chmods to exactly
      # this mode on every run, so a bit inherited from the parent — or set by
      # hand — is stripped again. The group of what lands here depends on it.
      mode = "2775";
    };
    "${libraryRoot}/audiobooks".d = {
      inherit (nixflix.globals.libraryOwner) user group;
      # ⚠ setgid, and tmpfiles is why it must be said: it chmods to exactly
      # this mode on every run, so a bit inherited from the parent — or set by
      # hand — is stripped again. The group of what lands here depends on it.
      mode = "2775";
    };
    "${libraryRoot}/manga".d = {
      inherit (nixflix.globals.libraryOwner) user group;
      # ⚠ setgid, and tmpfiles is why it must be said: it chmods to exactly
      # this mode on every run, so a bit inherited from the parent — or set by
      # hand — is stripped again. The group of what lands here depends on it.
      mode = "2775";
    };
  };

  # ── Reaching the host from the Docker bridge ──────────────────────────────
  # Prowlarr and SABnzbd bind 0.0.0.0 behind the firewall, so a container gets
  # them only with an interface-scoped opening — the same shape §5a prescribes
  # for `wg-br`. qBittorrent needs nothing here: it is confined, and nixflix
  # already port-maps its WebUI onto the veth.
  networking.firewall.interfaces.docker0.allowedTCPPorts = [
    prowlarrPort
    sabnzbdPort
  ];

  # ── Chaptarr — monitoring ─────────────────────────────────────────────────
  # Docker-only upstream (building needs .NET 10 + Node + Yarn + FFmpeg), so
  # this follows homepages.nix's idiom: pinned tag, loopback publish, sops env.
  # ⚠ `PUID`/`PGID` default to Unraid's 99:100 and land every import unreadable
  # here; `UMASK` is upstream's own recommendation when containers share a
  # media group, the same fix nixflix.nix applies to qBittorrent.
  virtualisation.oci-containers.containers.chaptarr = {
    # ⚠ Docker Hub's tags carry no `v` prefix, and `latest` is older than the
    # newest release — with pull="missing" a floating tag resolves once and
    # then never moves again (§4.2).
    image = "chaptarr/chaptarr:0.9.958";

    environment = {
      PUID = toString config.users.users.chaptarr.uid;
      # PGID arrives from the env file below, not from here — the gid does not
      # exist at evaluation time (§4.7).
      UMASK = "002";
      TZ = config.time.timeZone;

      # ASP.NET binds `Chaptarr__Section__Key` onto config.xml-level settings,
      # and that is the whole reach of env: `CopyUsingHardlinks` lives in the
      # SQLite Config table, and the login has no env path at all — both stay
      # MANUAL-STEPS items (§5). ⚠ `Chaptarr__Auth__Method` deliberately unset:
      # env wins on every start, so pinning Forms before the first-run wizard
      # has created an account locks the owner out of the account creation.
      Chaptarr__Server__Port = toString chaptarrPort;
      # Info, not Debug: the import path reports which transfer it actually
      # performed at Info, and that line is the only way to tell a hardlink
      # from a copy (§6).
      Chaptarr__Log__Level = "info";
    };

    environmentFiles = [
      config.sops.templates."chaptarr.env".path
      gidEnvFile
    ];
    ports = [ "127.0.0.1:${toString chaptarrPort}:${toString chaptarrPort}" ];

    volumes = [
      "${appdata}/chaptarr:/config"
      "${library}:${library}"
      "${downloadsDir}:${downloadsDir}"
    ];
  };

  # ── Shelfmark — on-demand search ──────────────────────────────────────────
  # The Lite image: no bundled Chromium, ~2 GB less RAM, and an external
  # resolver instead — here the dedicated one below, never Prowlarr's (§5d).
  virtualisation.oci-containers.containers.shelfmark = {
    image = "ghcr.io/calibrain/shelfmark-lite:v1.3.15";

    environment = {
      PUID = toString config.users.users.shelfmark.uid;
      # PGID arrives from the env file below, same as Chaptarr's — §4.7.
      UMASK = "002";
      TZ = config.time.timeZone;

      AUTH_METHOD = "builtin";
      INGEST_DIR = "/bookdrop";
      TMP_DIR = "/staging";

      # ── Egress: the proxy comes in as ENVIRONMENT, never the UI setting ───
      # Env covers all ~52 outbound call sites through `requests`' trust_env;
      # the web-UI setting covers 8 (§5c). `PROXY_MODE` is set too so
      # Shelfmark's own eight agree with the other forty-four.
      PROXY_MODE = "http";
      HTTP_PROXY = "http://${nsAddress}:${toString proxyPort}";
      HTTPS_PROXY = "http://${nsAddress}:${toString proxyPort}";
      # ⚠ Exact IP literals only. The env path is requests' suffix/plain-IP
      # matching, where `10.*` matches nothing, while the same variable is also
      # read by Shelfmark's own fnmatch mechanism — an exact address is the one
      # form both honour. The namespace address covers the dedicated
      # FlareSolverr and qBittorrent — without it the call to FlareSolverr,
      # which passes no `proxies=`, is dialled through the tunnel. The host
      # address covers Prowlarr and SABnzbd, the two that bind 0.0.0.0 and are
      # opened on docker0 below. ⚠ It does NOT reach Chaptarr or Grimmory:
      # both publish on loopback only, so Shelfmark cannot talk to them at
      # all — it delivers into the bookdrop instead (§5, finding 3).
      NO_PROXY = "localhost,127.0.0.1,${nsAddress},${hostAddress}";

      USING_EXTERNAL_BYPASSER = "true";
      EXT_BYPASSER_URL = "http://${nsAddress}:${toString bypasserPort}";

      # ── IRC and DCC: disabled, not merely unconfigured ────────────────────
      # Raw TCP to arbitrary ports with no SOCKS support at any layer, so only
      # a network namespace could contain them and Docker cannot give us one
      # (§5a). Upstream has no enable flag: the source is gated on these four
      # being non-empty. Empty here is still a real lock, because Shelfmark
      # treats any env var that is merely *present* as authoritative and
      # refuses to save over it from the UI — so turning IRC on is an edit to
      # this file, never a click.
      IRC_SERVER = "";
      IRC_CHANNEL = "";
      IRC_NICK = "";
      IRC_SEARCH_BOT = "";

      PROWLARR_ENABLED = "true";
      PROWLARR_URL = "http://${hostAddress}:${toString prowlarrPort}";
      PROWLARR_TORRENT_CLIENT = "qbittorrent";
      QBITTORRENT_URL = "http://${nixflix.torrentClients.qbittorrent.connectionAddress}:${toString nixflix.torrentClients.qbittorrent.webuiPort}";
      QBITTORRENT_USERNAME = "admin";
      SABNZBD_URL = "http://${hostAddress}:${toString sabnzbdPort}";
    };

    environmentFiles = [
      config.sops.templates."shelfmark.env".path
      gidEnvFile
    ];
    ports = [ "127.0.0.1:${toString shelfmarkPort}:${toString shelfmarkPort}" ];

    volumes = [
      "${appdata}/shelfmark:/config"
      "${stagingDir}:/staging"
      "${bookdropDir}:/bookdrop"
      # Identical path on both sides: Prowlarr-mode handoff only finds the
      # finished files if Shelfmark and the download client agree on the path.
      "${downloadsDir}:${downloadsDir}"
    ];
  };

  # ── Suwayomi — manga ──────────────────────────────────────────────────────
  # The one cleanly-solved piece: a native module in the pin, no container, no
  # pinning debt. CBZ lands in the library tree Grimmory reads; state stays in
  # appdata, which is why `downloadsPath` is set away from the dataDir default.
  services.suwayomi-server = {
    enable = true;
    dataDir = "${appdata}/suwayomi";
    group = mediaGroup;

    # ⚠ Ahead of the channel deliberately, and not for the version number:
    # nixpkgs' 2.1.1867 can only read the legacy `index.min.json`, which
    # Keiyoushi now serves as two "update your app" stubs — so it reaches zero
    # extensions and manga acquisition does not work at all. 2.3 resolves
    # repo.json → index_v2 → index.pb instead. MANUAL-STEPS.md §18 item 17.
    package = pkgs.suwayomi-server.overrideAttrs (_: rec {
      version = "2.3.2243";
      src = pkgs.fetchurl {
        url = "https://github.com/Suwayomi/Suwayomi-Server/releases/download/v${version}/Suwayomi-Server-v${version}.jar";
        hash = "sha256-ghFBsy4XDUoC08vf7Vd+2PB70iOD/19BMuu1rkDpjdU=";
      };
    });

    settings.server = {
      # Loopback: reached through Traefik, like everything else here.
      ip = "127.0.0.1";
      port = suwayomiPort;
      downloadAsCbz = true;
      downloadsPath = "${libraryRoot}/manga";

      # ⚠ Declared here rather than added in the WebUI, and that is not a
      # preference: the module re-renders server.conf from these settings on
      # every start, so anything the UI writes there is reverted at the next
      # restart. Keiyoushi is the community successor to Tachiyomi's own index,
      # which no longer exists; without a repo Suwayomi can browse nothing.
      # ⚠ Still the `index.min.json` URL although that file is now a stub, and
      # that is correct: the server strips the `/index.min.json` suffix and
      # fetches `<base>/repo.json`, which points it at the real index. Changing
      # this to the path it ultimately reads would break the derivation.
      extensionRepos = [
        "https://raw.githubusercontent.com/keiyoushi/extensions/repo/index.min.json"
      ];
    };
  };

  # ── A confined HTTP proxy — the pattern that actually works ───────────────
  # `vpnConfinement` on a Docker unit confines the docker CLI and leaves the
  # container in dockerd's namespaces: it renders cleanly and protects nothing
  # (§5a). A native proxy is a real systemd service, so confinement holds, and
  # Shelfmark only ever needed outbound HTTP inside the tunnel.
  services.tinyproxy = {
    enable = true;
    settings = {
      # ⚠ The namespace address, never loopback — same rule that makes Traefik
      # dial `connectionAddress` (§5a).
      Listen = nsAddress;
      Port = proxyPort;
      Timeout = 600;
      # ⚠ Load-bearing twice over. The DNAT rule matches on destination port
      # alone, so without an Allow list the proxy is an open relay for the LAN.
      # And the bridge address must be listed or NOTHING passes: the namespace
      # is not a local address, so a container's packet takes the forward path
      # through nat POSTROUTING, where Docker masquerades it to the bridge —
      # tinyproxy sees the bridge address, never 172.17.x.x. The subnet entry
      # matters only if masquerading is ever turned off. A LAN client is not
      # masqueraded, so it still fails the list, which is the point.
      Allow = [
        dockerBridgeSubnet
        config.vpnNamespaces.${netns}.bridgeAddress
      ];
      DisableViaHeader = true;
      LogLevel = "Warning";
      # No `ConnectPort` lines on purpose: tinyproxy permits CONNECT to any
      # port only while none is listed, and these sources are not all on :443.
    };
  };

  systemd.services.tinyproxy.vpnConfinement = {
    enable = true;
    vpnNamespace = netns;
  };

  # ── Shelfmark's own FlareSolverr, confined ────────────────────────────────
  # ⚠ Prowlarr's instance stays unconfined: nixflix hardcodes
  # http://127.0.0.1:8191 for its indexer proxy, and a VPN exit makes
  # Cloudflare *harsher* on the one job FlareSolverr has (§5d.4). Neither
  # instance is routed through Traefik — an unauthenticated endpoint that
  # fetches arbitrary URLs through a real browser (§7).
  # mkIf because the serviceConfig below is inherited from the shared instance:
  # with that disabled this would render a unit with no ExecStart. ⚠ Gated on
  # nixflix's option, not nixpkgs' `services.flaresolverr.enable`: the latter is
  # what nixflix sets *downstream*, so gating on it would make this twin's
  # existence depend on an implementation detail of the module that enables it.
  # Both evaluate true today; this is the one that cannot drift.
  systemd.services.flaresolverr-shelfmark = lib.mkIf nixflix.flaresolverr.enable {
    description = "FlareSolverr (Shelfmark's own, inside the ${netns} namespace)";
    after = [ "network.target" ];
    wantedBy = [ "multi-user.target" ];

    vpnConfinement = {
      enable = true;
      vpnNamespace = netns;
    };

    # 0.0.0.0 is the *namespace's* 0.0.0.0, so this answers on the namespace
    # address and nowhere on the host.
    environment = {
      HOME = "/run/flaresolverr-shelfmark";
      HOST = "0.0.0.0";
      PORT = toString bypasserPort;
    };

    # Inherit the shared instance's evaluated serviceConfig — nixpkgs'
    # hardening plus the raised TimeoutStartSec — so the twin tracks both
    # across bumps instead of drifting, as bazarr.nix's anime twin does. Only
    # the per-instance keys are restated.
    serviceConfig =
      builtins.removeAttrs config.systemd.services.flaresolverr.serviceConfig [
        "ExecStartPost"
        "RuntimeDirectory"
        "WorkingDirectory"
        "SyslogIdentifier"
      ]
      // {
        SyslogIdentifier = "flaresolverr-shelfmark";
        RuntimeDirectory = "flaresolverr-shelfmark";
        WorkingDirectory = "/run/flaresolverr-shelfmark";

        # The same 180s probe the shared instance carries, for the same reason
        # and with the same TimeoutStartSec pairing — argued once in
        # nixflix.nix's FlareSolverr block, not re-derived here.
        ExecStartPost = pkgs.writeShellScript "wait-for-flaresolverr-shelfmark" ''
          ${pkgs.curl}/bin/curl -sf --retry 180 --retry-delay 1 --retry-all-errors --retry-connrefused \
            --max-time 5 --retry-max-time 180 \
            http://127.0.0.1:${toString bypasserPort}/ >/dev/null 2>&1 || {
            echo "FlareSolverr (shelfmark) did not become ready within 180s" >&2
            exit 1
          }
        '';
      };
  };

  # ── Namespace wiring ──────────────────────────────────────────────────────
  # `portMappings`, not `openVPNPorts`: the latter opens the port on wg0, the
  # tunnel side, where no container will ever arrive. This is also what adds
  # the netns INPUT rule — its policy is DROP, so nothing is reachable without
  # it. ⚠ It DNATs on destination port alone; see tinyproxy's `Allow`.
  vpnNamespaces.${netns}.portMappings = [
    {
      from = proxyPort;
      to = proxyPort;
      protocol = "tcp";
    }
    {
      from = bypasserPort;
      to = bypasserPort;
      protocol = "tcp";
    }
  ];

  # ⚠ Merged with nixflix.nix's LAN entry, not replacing it. `accessibleFrom`
  # rather than `allowedEgress` because a reply is ESTABLISHED and already
  # passes the kill switch. (`allowedEgress` does take a CIDR — but
  # 192.168.15.0/24 specifically collides with the connected veth route and
  # fails wg.service on switch, §5a.) ⚠ This route is not what carries replies
  # today: Docker masquerades the container to the bridge address, so the reply
  # destination is directly connected. It becomes load-bearing the moment
  # masquerading is off.
  nixflix.vpn.accessibleFrom = [ dockerBridgeSubnet ];

  # ── Ordering: nothing starts before tank is imported ──────────────────────
  # Derived from nixflix's own list rather than naming zfs-mount.service again,
  # so this follows if the host's storage wiring changes.
  # ⚠ RequiresMountsFor as well as the ordering below, the pattern karakeep.nix
  # and bazarr.nix already set: tank's crypttab entries are all `nofail`, so a
  # degraded boot with the array unimported is a real state, and ordering on
  # zfs-mount alone would still let docker.service start these against empty
  # bind-mount sources — which Docker then materialises as root-owned
  # directories on the root filesystem.
  systemd.services = {
    docker-chaptarr = {
      after = nixflix.serviceDependencies ++ [ "reading-media-gid.service" ];
      requires = nixflix.serviceDependencies ++ [ "reading-media-gid.service" ];
      unitConfig.RequiresMountsFor = [
        "${appdata}/chaptarr"
        library
        downloadsDir
      ];
    };
    docker-shelfmark = {
      after = nixflix.serviceDependencies ++ [ "reading-media-gid.service" ];
      requires = nixflix.serviceDependencies ++ [ "reading-media-gid.service" ];
      unitConfig.RequiresMountsFor = [
        "${appdata}/shelfmark"
        stagingDir
        bookdropDir
        downloadsDir
      ];
    };
    suwayomi-server = {
      after = nixflix.serviceDependencies;
      requires = nixflix.serviceDependencies;
      # Suwayomi's user is not the library owner, so its CBZ has to land
      # group-writable for Grimmory to manage it afterwards.
      serviceConfig.UMask = "0002";
    };

    # Chaptarr is not in Prowlarr's application list yet (§5b leaves the sync
    # unproven and the list is nixflix's to own), but the ordering edge is
    # cheap now and easy to forget later: prowlarr-applications orders itself
    # after the four *arrs only, runs `set -eu`, and exits 1 on a failed PUT.
    prowlarr-applications = lib.mkIf nixflix.prowlarr.enable {
      after = [ "docker-chaptarr.service" ];
      wants = [ "docker-chaptarr.service" ];
    };
  };

  # ── Routes ────────────────────────────────────────────────────────────────
  # The `read.*` domain group's own contract (traefik-galactica.nix); nothing
  # derives these, so each service registers itself. Ports are published on
  # loopback, so loopback is the honest upstream — as in bazarr.nix, and unlike
  # a confined service, which must be dialled on its namespace address.
  homelab.readUpstreams = {
    chaptarr = "http://127.0.0.1:${toString chaptarrPort}";
    shelfmark = "http://127.0.0.1:${toString shelfmarkPort}";
    suwayomi = "http://127.0.0.1:${toString suwayomiPort}";
  };

  # ── sops-nix ──────────────────────────────────────────────────────────────
  # ⚠ Every secret must exist before sops-nix activates or the switch fails.
  # Only Chaptarr needs a new one; Shelfmark's three are the nixflix values it
  # authenticates to Prowlarr, qBittorrent and SABnzbd with, reused the way
  # homepages.nix reuses them rather than kept twice.
  sops.secrets."reading/chaptarrApiKey" = { };

  sops.templates."chaptarr.env".content = ''
    Chaptarr__Auth__ApiKey=${config.sops.placeholder."reading/chaptarrApiKey"}
  '';

  sops.templates."shelfmark.env".content = ''
    PROWLARR_API_KEY=${config.sops.placeholder."nixflix/prowlarrApiKey"}
    QBITTORRENT_PASSWORD=${config.sops.placeholder."nixflix/qbittorrentPassword"}
    SABNZBD_API_KEY=${config.sops.placeholder."nixflix/sabnzbdApiKey"}
  '';
}
