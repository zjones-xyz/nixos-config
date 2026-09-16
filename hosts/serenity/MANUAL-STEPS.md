# serenity — manual steps

Steps that can't be expressed in the flake, or that need Zoe at the Mac.

## 1. Colima: first start

Colima's VM state (`~/.colima/`, `~/.lima/`) lives outside the flake. Only the
binaries are declared (see `DECISIONS.md` §1). Do this once after the `drs` that
brings in `colima`/`docker-client`, ideally **before** the workshop, since the
first start downloads a VM image.

Defaults in 0.10.1: **2 CPUs, 2 GiB RAM, 100 GiB disk**, `vz` VM type with
`virtiofs` mounts (macOS 13+). The disk is a sparse file, so 100 GiB is only a
maximum, not space used up front, but it **can be grown later and never
shrunk**. 2 GiB of RAM is tight once Qdrant plus a client app are running, so
size the VM up a little on first start:

1. [ ] `colima start --cpus 2 --memory 4 --disk 30`
       — flags given on the first start are saved to
       `~/.colima/default/colima.yaml` and reused by every later plain
       `colima start`. To change them later: `colima stop`, then
       `colima start --memory 6` (or `colima start --edit`).
2. [ ] `docker context ls` shows `colima *` (Colima created it and switched to
       it; no `DOCKER_HOST` needed).
3. [ ] `docker compose version` and `docker buildx version` both print a
       version (the plugins come bundled with nixpkgs' docker CLI).
4. [ ] `docker run --rm hello-world` prints "Hello from Docker!".
5. [ ] `docker run -d --name qdrant -p 6333:6333 qdrant/qdrant`, wait a few
       seconds, then `curl -s http://localhost:6333/healthz` prints
       `healthz check passed`.
6. [ ] `docker rm -f qdrant`, then `colima stop` (removes the `colima` context
       too). Nothing autostarts at login. The pulled images stay in the VM, so
       the workshop won't need to download Qdrant again.

If a workshop image turns out to be amd64-only, recreate the VM with Rosetta
enabled: `colima delete`, then `colima start --vz-rosetta …` with the flags
above. `colima delete` wipes all images and volumes.
