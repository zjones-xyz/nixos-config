{ config, pkgs, lib, ... }:

# ─────────────────────────────────────────────────────────────────────────────
# paperless-ngx — document management for Tower's scanned-document trove.
# ─────────────────────────────────────────────────────────────────────────────
# Starting-point scaffold. Wires nixpkgs' `services.paperless` (nixos-26.05)
# with its storage split across three tank datasets by tier, and its Postgres
# on the special vdev. Ingress is deliberately NOT here — see the TODO at the
# bottom. Owner supplies the sops secret; until then this evaluates with
# paperless left off (see the two gates below).
#
# ── Why the storage is split three ways (not one dir under /var/lib) ─────────
# paperless keeps three very different kinds of state, and on this host they map
# onto three different tank datasets with three different `homelab:tier` values:
#
#   1. media (originals + OCR'd archive PDFs)  → CRITICAL, irreplaceable.
#      These are the actual scanned documents. They belong on the RAIDZ1
#      spinners with the rest of the Critical `documents` trove, where they get
#      parity redundancy AND the Critical tier's snapshot/versioning policy.
#      Placed as a *child* of the existing `tank/documents` dataset so it
#      inherits that subtree's tier and snapshot regime rather than inventing a
#      new one — it is, semantically, part of the documents corpus.
#        mediaDir = /tank/documents/paperless
#
#   2. data (search index, ML classifier models, the generated secret key,
#      superuser-state marker)                → REGENERABLE / REACQUIRABLE.
#      The Whoosh index reindexes from the DB; the classifier retrains; the
#      secret key only gates session cookies. None of it is irreplaceable, so
#      it lives on `tank/services`, not in the Critical subtree.
#        dataDir  = /tank/services/paperless
#      consume (the watch dir) is transient — paperless deletes files after
#      import — so it's just a subdir of dataDir, no separate dataset.
#        consumptionDir = /tank/services/paperless/consume
#
#   3. Postgres (document metadata: tags, correspondents, dates, OCR text)
#                                             → PRECIOUS. Not the blobs, but the
#      hand-curated organisation *of* the blobs — hours of human labour, and not
#      regenerable by re-OCR. Wants low latency and its own redundancy, so it
#      goes on the special-vdev-backed `appdata` (the 3-way SSD mirror), via a
#      dedicated child dataset. See the `services.postgresql.dataDir` note.
#        PGDATA = /tank/appdata/paperless
#
# All three datasets are `zfs create`d by hand on Tower (no live host here) —
# MANUAL-STEPS.md §12 has the exact commands and the recommended per-dataset
# ZFS properties (Postgres in particular wants recordsize=16K, logbias=
# throughput, atime=off). The paths are declared here as plain strings, so this
# evaluates fine before any of them exist — same "declare config for storage
# built live" discipline the host's tank import already follows.

let
  # ── The master gate — an EXPLICIT owner switch, default off ─────────────────
  # Deliberately NOT `builtins.pathExists secrets/galactica-array.key`: that file
  # is already committed (the array is built), so gating on it would flip
  # paperless ON at the very next `switch` — before the datasets below exist and
  # before the admin secret is added. paperless would then let systemd-tmpfiles
  # create PLAIN directories under `tank/documents` / `tank/appdata` instead of
  # the per-tier child datasets (wrong snapshot boundary, wrong tier, and a
  # PGDATA that's painful to relocate afterwards), and crash-loop on the missing
  # secret. So enablement is a single deliberate flip the owner makes as the LAST
  # step of MANUAL-STEPS §12, once the datasets and the admin secret both exist.
  # Until then this module is inert and the whole config evaluates cleanly.
  paperlessReady = false; # ← flip to true after MANUAL-STEPS §12 (datasets + secret)

  # The admin superuser password is a sops secret; gate its declaration/use on
  # the secrets file existing too, so eval never forces a secret path that has no
  # sops backing (matches configuration.nix's own hasSops discipline).
  hasSops = builtins.pathExists ../../secrets/galactica.yaml;

  mediaDir   = "/tank/documents/paperless";     # CRITICAL: originals + archive
  dataDir    = "/tank/services/paperless";      # regenerable: index/models/keys
  consumeDir = "${dataDir}/consume";            # transient watch dir
  pgDataDir  = "/tank/appdata/paperless";       # precious: PG on the special vdev
in
{
  services.paperless = lib.mkIf paperlessReady {
    enable = true;
    inherit dataDir mediaDir;
    consumptionDir = consumeDir;

    # ── Postgres, not SQLite ──────────────────────────────────────────────────
    # `createLocally` stands up a local PostgreSQL, gives paperless a DB + role,
    # and authenticates over the unix socket via peer auth — so there is NO DB
    # password to manage as a secret. SQLite would technically work, but this is
    # the owner's real long-lived document store, not a toy: Postgres is the
    # upstream-recommended engine for concurrent OCR workers + the web/consumer/
    # scheduler services all hitting the DB at once, it doesn't suffer SQLite's
    # single-writer lock stalls under the task-queue load, and it's the format
    # paperless's own `document_exporter`/importer round-trips cleanly for
    # backups. On ZFS it also lands on the special-vdev mirror (below), which a
    # single SQLite file wouldn't earn on its own.
    database.createLocally = true;

    # Admin (superuser) password for the web UI. LoadCredential reads this as
    # root before dropping privileges, so the default root-owned sops secret is
    # fine — no `.owner` needed. Only wired when the secrets file exists; with it
    # unset (e.g. before the `paperless/adminPassword` entry is added) paperless
    # still starts, and the owner makes a superuser by hand with
    # `paperless-manage createsuperuser`.
    passwordFile = lib.mkIf hasSops config.sops.secrets."paperless/adminPassword".path;

    settings = {
      # English only, explicitly — this also trims the tesseract build to
      # equ/osd/eng instead of every language pack. Add more with a `+`, e.g.
      # "eng+deu"; each added code enlarges the tesseract rebuild. (Open
      # question flagged in the PR: does the trove need any non-English OCR?)
      PAPERLESS_OCR_LANGUAGE = "eng";

      # address/port keep their defaults (127.0.0.1:28981). Ingress is handled
      # out-of-band (tsdproxy, separate repo — see the TODO below), so paperless
      # binds loopback only and no firewall port is opened here.
    };

    # NB: PAPERLESS_SECRET_KEY is intentionally NOT set here. The upstream module
    # generates a strong 64-char key on first start and persists it at
    # `${dataDir}/nixos-paperless-secret-key`; putting it in `settings` would
    # leak it into the world-readable Nix store. If a *pre-existing* paperless
    # instance is ever migrated in (its key must be preserved to keep sessions/
    # tokens valid), pass it via `environmentFile` pointing at a sops secret
    # containing `PAPERLESS_SECRET_KEY=…`, not via `settings`.
  };

  # ── Postgres onto the special-vdev-backed dataset ───────────────────────────
  # `createLocally` enables the system PostgreSQL; point its data directory at
  # the `appdata` dataset so the DB gets the 3-way SSD mirror's latency and
  # redundancy instead of sitting on the RAIDZ1 spinners. The dataset itself
  # (and its ZFS tuning) is an owner `zfs create` — MANUAL-STEPS.md §12. On a
  # major PostgreSQL upgrade this fixed path needs the usual dump/restore dance
  # (no version subdir), which is acceptable for a single-service cluster.
  services.postgresql.dataDir = lib.mkIf paperlessReady pgDataDir;

  # Declared only when paperless is on AND the secrets file exists — declaring a
  # secret that isn't in the yaml yet would warn at activation. Owner creates
  # `paperless/adminPassword` in secrets/galactica.yaml (MANUAL-STEPS.md §12).
  # defaultSopsFile/age keys come from configuration.nix.
  sops.secrets = lib.mkIf (paperlessReady && hasSops) {
    "paperless/adminPassword" = { };
  };

  # ── Ingress — OUT OF SCOPE here (TODO) ──────────────────────────────────────
  # No tailscale, no reverse proxy, no firewall opening in this module. The
  # intended access path is a Tailscale-fronted tsdproxy route defined in the
  # separate `homelab_stacks` repo (see HOMELAB_STACKS_HANDOFF.md), pointed at
  # this host's loopback 127.0.0.1:28981. When that lands, paperless also needs
  # `settings.PAPERLESS_URL` set to its external origin (and CSRF trusted
  # origins) — deferred until the hostname is decided.
}
