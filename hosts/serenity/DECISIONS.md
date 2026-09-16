# serenity — decision log

Each entry: **decision → alternatives → rationale.**

## 1. Container runtime: Colima + nixpkgs docker CLI

**Decision:** `colima` and `docker-client` from nixpkgs, in `home.packages`
(`hosts/serenity/home.nix`). No launchd agent — the VM runs only after a manual
`colima start`. First needed for a workshop (`docker run qdrant/qdrant`, possibly
a compose file).

**Alternatives:** Docker Desktop, OrbStack (both Homebrew casks).

**Rationale:**

- **Free.** Colima is MIT; Docker Desktop's license is paid for larger
  organizations, and OrbStack is free for personal use only.
- **Declarative.** Both packages come from the pinned nixpkgs and are cached for
  aarch64-darwin, so a `drs` fully reproduces the setup. The casks are GUI
  apps that update themselves and keep their own state outside the flake.
- **No license or sign-in prompt** on first run, and no always-on menu-bar
  daemon. The VM exists only between `colima start` and `colima stop`.

**Trade-off accepted:** no GUI and less polish than OrbStack (file-sharing speed,
automatic memory reclaim). That doesn't matter for a small, occasional workload.

### Packaging notes (nixpkgs 26.05 pin)

- `docker-client` (29.7.2) is the CLI only. On darwin, `docker` is the same build
  anyway (`clientOnly` defaults to true off Linux), but `docker-client` makes
  the intent explicit.
- **Compose and buildx are already included.** nixpkgs builds the CLI with
  `composeSupport`/`buildxSupport` and its wrapper sets `DOCKER_CLI_PLUGIN_DIRS`,
  so `docker compose …` and `docker buildx …` work without listing
  `docker-compose` or `docker-buildx`. The separate `docker-compose` package is
  only needed for the old hyphenated `docker-compose` command, which isn't used here.
- `colima` (0.10.1) is wrapped with `lima-full`, `qemu` and `krunkit` on its
  PATH, so none of those need to be listed.

### Docker socket discovery: a context, not `DOCKER_HOST`

Checked against the Colima 0.10.1 source (`environment/container/docker/`):
`colima start` runs `docker context create colima …` and then
`docker context use colima`. The second step is skipped only when `autoActivate: false` is set
in `~/.colima/default/colima.yaml`, and it defaults to on. `colima stop` removes the
context again. So nothing is set declaratively. Setting `DOCKER_HOST` would
actually be worse, because it overrides the context and would point at a dead
socket whenever the VM is down.

⚠ The context is recorded in `~/.docker/config.json`. If Home Manager ever
manages that file (a read-only store symlink), `docker context use` fails and
this decision needs revisiting.
