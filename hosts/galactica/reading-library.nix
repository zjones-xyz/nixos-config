{ config, pkgs, lib, ... }:

# ── The reading stack, client half ───────────────────────────────────────────
# Grimmory (ebooks, comics/manga, audiobook files) with the MariaDB it cannot
# run without, Audiobookshelf (audiobooks, podcasts) and BookBridge
# reconciling read progress between the two. READING-STACK.md is the spec: §3
# for why the audiobooks deliberately live in two libraries, §7 for the
# `*.read.*` names and why auth is local accounts for now (no OIDC here).
# Acquisition — Chaptarr, Shelfmark, Suwayomi — is reading-acquisition.nix.

let
  # The library's group — shared with the *arr trees so what one stack writes
  # the other can read. ⚠ Name only: `users.groups.media.gid` evaluates to null
  # here, so the number arrives at unit-start time instead, from the resolver in
  # reading-acquisition.nix (READING-STACK.md §4.7).
  mediaGroup = config.nixflix.globals.libraryOwner.group;

  # ── Paths ─────────────────────────────────────────────────────────────────
  # /tank/books is its OWN dataset, inverting nixflix's one-layout rule:
  # `homelab:tier` is a dataset property and `books` is Protected, so books
  # under nixflix_media could not carry their own tier (READING-STACK.md §6).
  # bookdrop is a sibling of the library root rather than inside it, so a
  # half-imported drop is never scanned as library content.
  booksDir = "/tank/books/library";
  bookdropDir = "/tank/books/bookdrop";

  # State on the special vdev's SSD mirror with the rest of appdata — the same
  # choice nixflix.nix's stateDir makes (DECISIONS.md §7).
  stateDir = name: "/tank/appdata/${name}";
  absDir = stateDir "audiobookshelf";
  abs = config.services.audiobookshelf;

  # ⚠ Pinned exactly, for the reason homepages.nix already carries: with the
  # oci-containers default pull = "missing" a floating tag resolves once and
  # then never updates again. Bump these deliberately, never by routine.
  grimmoryImage = "ghcr.io/grimmory-tools/grimmory:v3.4.0";
  # MariaDB's own image, not the linuxserver one upstream's compose shows: a
  # plain /var/lib/mysql datadir and the MARIADB_* names a borgmatic
  # `mariadb-dump` hook (§4.3) expects. 11.4 is the LTS line upstream tracks.
  mariadbImage = "mariadb:11.4.13";
  bookbridgeImage = "ghcr.io/cporcellijr/bookbridge:7.6.0";

  # Loopback-only publishes, as homepages.nix does — all three arrive through
  # Traefik, and MariaDB is not reached from off-box at all.
  grimmoryPort = 6060;
  mariadbPort = 3306;
  bookbridgePort = 5757;

  dbName = "grimmory";
  dbUser = "grimmory";

  # The uid the Grimmory image's own account carries (also `z` here); both
  # USER_ID and the owner of its state directory need it. The group comes from
  # GROUP_ID in the resolver's env file, plus the setgid bit on the library
  # tree — see mediaGroup.
  grimmoryUid = 1000;
in
{
  # ── Secrets ───────────────────────────────────────────────────────────────
  # ⚠ Every one must exist before sops-nix activates or the switch fails — the
  # nixflix.nix precedent. ⚠ BOOKBRIDGE_SECRET_KEY comes from sops on purpose:
  # unset, BookBridge generates it into /data/secret.key, beside the ciphertext
  # it protects, and every linked account (including Grimmory's password) falls
  # out of a stolen snapshot. READING-STACK.md §4.5.
  sops.secrets = {
    "reading/grimmoryDbPassword" = { };
    "reading/grimmoryDbRootPassword" = { };
    "reading/bookbridgeSecretKey" = { };
    "reading/bookbridgeWebSecretKey" = { };
  };

  sops.templates."grimmory.env".content = ''
    DATABASE_PASSWORD=${config.sops.placeholder."reading/grimmoryDbPassword"}
  '';

  # ⚠ MariaDB reads these only while INITIALISING an empty datadir. Rotating
  # either afterwards is an `ALTER USER` inside the database, not a switch.
  sops.templates."grimmory-mariadb.env".content = ''
    MARIADB_ROOT_PASSWORD=${config.sops.placeholder."reading/grimmoryDbRootPassword"}
    MARIADB_PASSWORD=${config.sops.placeholder."reading/grimmoryDbPassword"}
  '';

  # WEB_SECRET_KEY as well as the Fernet key: sessions then survive a restore
  # instead of logging everyone out.
  sops.templates."bookbridge.env".content = ''
    BOOKBRIDGE_SECRET_KEY=${config.sops.placeholder."reading/bookbridgeSecretKey"}
    WEB_SECRET_KEY=${config.sops.placeholder."reading/bookbridgeWebSecretKey"}
  '';

  # ── The three containers ──────────────────────────────────────────────────
  # All on the `proxy` network traefik-galactica.nix already creates: Docker's
  # embedded DNS resolves container names only on a user-defined network, and
  # DATABASE_URL has to name one. Traefik picks up nothing from them —
  # exposedByDefault is false and none of them carries a label.
  virtualisation.oci-containers.containers = {
    grimmory = {
      image = grimmoryImage;
      environment = {
        TZ = config.time.timeZone;
        DATABASE_URL = "jdbc:mariadb://grimmory-mariadb:${toString mariadbPort}/${dbName}";
        DATABASE_USERNAME = dbUser;
        # GROUP_ID is not here: it comes from the resolver's env file below,
        # because the gid does not exist at evaluation time.
        USER_ID = toString grimmoryUid;
        SWAGGER_ENABLED = "false";
        # ⚠ DISK_TYPE stays unset (= local). It selects NFS/SMB-safe file
        # handling, and /tank/books is a local dataset — that this host also
        # *exports* NFS is irrelevant here.
        # OIDC is left merely unconfigured rather than FORCE_DISABLE_OIDC'd:
        # §7 defers a provider, and a forced disable is a second thing to undo.
      };
      # ⚠ The second file carries GROUP_ID, resolved at unit-start time because
      # the `media` gid does not exist at evaluation (READING-STACK.md §4.7).
      # Grimmory needs it to write the bookdrop: Shelfmark's entrypoint chowns
      # that directory to `shelfmark:media` on every start, so uid ownership
      # alone would leave Grimmory able to read but not ingest out of it.
      environmentFiles = [
        config.sops.templates."grimmory.env".path
        "/run/reading/media-gid.env"
      ];
      ports = [ "127.0.0.1:${toString grimmoryPort}:${toString grimmoryPort}" ];
      volumes = [
        "${stateDir "grimmory"}:/app/data"
        "${booksDir}:/books"
        "${bookdropDir}:/bookdrop"
      ];
      # ⚠ No `dependsOn` — the ordering is declared below as `after` alone.
      extraOptions = [ "--network=proxy" ];
    };

    grimmory-mariadb = {
      image = mariadbImage;
      environment = {
        TZ = config.time.timeZone;
        MARIADB_DATABASE = dbName;
        MARIADB_USER = dbUser;
      };
      environmentFiles = [ config.sops.templates."grimmory-mariadb.env".path ];
      volumes = [ "${stateDir "grimmory-mariadb"}:/var/lib/mysql" ];
      # Published for the borgmatic MariaDB hook (§4.3), which dials TCP from
      # the host — Grimmory itself reaches it over the container network. No
      # port is opened in the firewall, so loopback is all it is.
      ports = [ "127.0.0.1:${toString mariadbPort}:${toString mariadbPort}" ];
      extraOptions = [ "--network=proxy" ];
    };

    bookbridge = {
      image = bookbridgeImage;
      environment = {
        TZ = config.time.timeZone;
        # ⚠ DATA_DIR is deliberately absent: its Alembic config hardcodes
        # /data and never reads the variable, so a custom value points the
        # migrations and the app at different files. ⚠ KOSYNC_PORT likewise —
        # split-port mode is purely additive and Traefik narrows routes better.
      };
      environmentFiles = [ config.sops.templates."bookbridge.env".path ];
      ports = [ "127.0.0.1:${toString bookbridgePort}:${toString bookbridgePort}" ];
      # ⚠ /data must stay on local storage: on NFS/CIFS/fuse BookBridge
      # silently drops out of WAL into DELETE journal mode. The library is
      # read-only — it matches books, it does not manage them. ⚠ Which
      # libraries it syncs is set in its own UI. It does reach Audiobookshelf
      # (verified on the host; §4.6), but only because this host's resolv.conf
      # is Tailscale's rather than a loopback nameserver — a dependency nothing
      # here declares. Suspect resolution first if it ever stops.
      volumes = [
        "${stateDir "bookbridge"}:/data"
        "${booksDir}:/books:ro"
      ];
      extraOptions = [ "--network=proxy" ];
    };
  };

  # ── Audiobookshelf ────────────────────────────────────────────────────────
  # The native module; `media` as its PRIMARY group, like bazarr.nix, so it can
  # read the audiobook tree Grimmory also indexes (§3). Libraries are added in
  # its UI — the module has no option for them. ⚠ Its podcast library wants a
  # dataset of its own: podcasts are Re-acquirable, and tier is a dataset
  # property (§6), so podcasts under /tank/books would be over-protected.
  services.audiobookshelf = {
    enable = true;
    group = mediaGroup;
    # Reached through Traefik only.
    openFirewall = false;
  };

  # ── Ordering, and the state Audiobookshelf's module cannot place ──────────
  # ⚠ tank is imported in stage-2 after the LUKS opens — nixflix declares the
  # same dependency via serviceDependencies. More than ordering for the
  # containers: Docker creates a missing bind-mount source as an empty
  # root-owned directory, occupying the mountpoint `zfs create` needs.
  # mkMerge, not `//`, which would drop the ordering it is merged onto.
  systemd.services = lib.mkMerge [
    (lib.genAttrs
      [
        "docker-grimmory"
        "docker-grimmory-mariadb"
        "docker-bookbridge"
      ]
      (_: {
        # docker-proxy-network creates the network above; today only the socket
        # proxy pulls it in, so these ask for it themselves. tank's dependency
        # is derived from nixflix's own list rather than naming zfs-mount again,
        # so it follows if the host's storage wiring changes.
        after = config.nixflix.serviceDependencies ++ [ "docker-proxy-network.service" ];
        requires = config.nixflix.serviceDependencies ++ [ "docker-proxy-network.service" ];
      })
    )

    # ⚠ RequiresMountsFor as well as the ordering above — the pattern
    # karakeep.nix and bazarr.nix already set. tank's crypttab entries are all
    # `nofail`, so a degraded boot with the array unimported is a real state,
    # and ordering on zfs-mount alone would still let docker.service start these
    # against empty bind-mount sources, which Docker materialises as root-owned
    # directories on the root filesystem.
    {
      # Ordered after the gid resolver as well: its env file carries GROUP_ID.
      # ⚠ MariaDB is ordered here rather than via `dependsOn`, which would also
      # render `Requires=` — and Requires propagates stops, so a flapping
      # MariaDB cycles Grimmory at systemd's pace, ignoring RestartSec below and
      # burning its start limit in seconds. MANUAL-STEPS.md §18 item 6.
      docker-grimmory.after = [
        "reading-media-gid.service"
        "docker-grimmory-mariadb.service"
      ];
      docker-grimmory.requires = [ "reading-media-gid.service" ];
      docker-grimmory.unitConfig.RequiresMountsFor = [
        (stateDir "grimmory")
        booksDir
        bookdropDir
      ];
      docker-grimmory-mariadb.unitConfig.RequiresMountsFor = [ (stateDir "grimmory-mariadb") ];
      docker-bookbridge.unitConfig.RequiresMountsFor = [
        (stateDir "bookbridge")
        booksDir
      ];
      audiobookshelf.unitConfig.RequiresMountsFor = [ absDir ];
    }

    {
      # ⚠ compose's `depends_on: service_healthy` has no oci-containers
      # equivalent, so Grimmory's first start races MariaDB initialising its
      # datadir and exits. The restart IS the wait loop, paced so the
      # 5-starts-in-10s limit cannot make it fatal. ⚠ It only covers Grimmory's
      # own exit — see the `after` above for why MariaDB is not a `Requires=`.
      docker-grimmory.serviceConfig.RestartSec = 15;

      audiobookshelf = {
        after = config.nixflix.serviceDependencies;
        requires = config.nixflix.serviceDependencies;

        # ⚠ `services.audiobookshelf.dataDir` is a name under /var/lib, not a
        # path, so the option cannot move state onto the appdata mirror — the
        # wrapper's --config/--metadata can, and both are real flags it
        # getopt-parses and honours absolutely. Safe to write outside the unit's
        # StateDirectory: the module sets no ProtectSystem, ProtectHome or
        # ReadWritePaths (verified on the evaluated host), so nothing sandboxes
        # it. ⚠ StateDirectory stays, so an empty /var/lib/audiobookshelf is
        # still created and remains the cwd — state is not there.
        # mkForce because nixpkgs defines
        # ExecStart; the host and port still come from the module's options.
        serviceConfig.ExecStart = lib.mkForce (
          "${lib.getExe abs.package} --host ${abs.host} --port ${toString abs.port}"
          + " --config ${absDir}/config --metadata ${absDir}/metadata"
        );
      };
    }
  ];

  # Created here because the alternative is Docker making them root-owned.
  # Grimmory's belongs to the uid inside its image; MariaDB's and BookBridge's
  # stay root-only — one holds every linked account's credentials (§4.5), the
  # other the database they sit in. ⚠ Nothing under /tank/books: that is a
  # dataset the owner creates, and a directory made first blocks the mount.
  systemd.tmpfiles.settings."11-reading-library" = {
    ${stateDir "grimmory"}.d = {
      user = toString grimmoryUid;
      group = mediaGroup;
      mode = "0750";
    };
    ${stateDir "grimmory-mariadb"}.d = {
      user = "root";
      group = "root";
      mode = "0700";
    };
    ${stateDir "bookbridge"}.d = {
      user = "root";
      group = "root";
      mode = "0700";
    };
    "${absDir}/config".d = {
      user = abs.user;
      group = mediaGroup;
      mode = "0750";
    };
    "${absDir}/metadata".d = {
      user = abs.user;
      group = mediaGroup;
      mode = "0750";
    };
  };

  # ── Routes ────────────────────────────────────────────────────────────────
  # Registered rather than listed in traefik-galactica.nix, so each port stays
  # written once. Names become `<name>.read.{internal,zjones.dev}` on the read
  # group's shared wildcard. Audiobookshelf's upstream is derived from its own
  # bind address, the module's `connectionAddress` reasoning; for the two
  # containers the published loopback address IS the host-side truth.
  homelab.readUpstreams = {
    grimmory = "http://127.0.0.1:${toString grimmoryPort}";
    audiobookshelf = "http://${abs.host}:${toString abs.port}";
    bookbridge = "http://127.0.0.1:${toString bookbridgePort}";
  };
}
