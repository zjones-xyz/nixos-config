# serenity — manual steps

Steps that can't be expressed in the flake, or that need Zoe at the Mac.

## 1. ✅ Colima: first start — done 2026-09-16

Colima's VM state (`~/.colima/`, `~/.lima/`) lives outside the flake. Only the
binaries are declared (see `DECISIONS.md` §1).

The first `colima start --cpus 2 --memory 4 --disk 30` took 30s, including the
VM image download. Those flags are saved to `~/.colima/default/colima.yaml`, so
a plain `colima start` reuses them. The defaults would have been 2 GiB RAM
(tight for Qdrant plus a client) and a 100 GiB disk (sparse, but it can be grown
and never shrunk). To resize: `colima stop`, then `colima start --memory 6`
(or `colima start --edit`).

The smoke test passed on the hardware: `colima start` made `colima` the active
docker context (no `DOCKER_HOST`), the engine inside the VM was docker 29.2.1 on
linux/arm64, `docker run --rm hello-world` pulled and ran the arm64 image, and
`qdrant/qdrant` on `-p 6333:6333` answered `healthz check passed` at
`http://localhost:6333/healthz`. After `docker rm -f qdrant && colima stop`, the
context switched back to `default`. The Qdrant image stays cached in the VM.

**Day-to-day:** `colima start` … `colima stop`. Nothing autostarts at login. If
`docker` says it failed to connect to `unix:///var/run/docker.sock`, the VM is
simply not running.

If a workshop image turns out to be amd64-only, recreate the VM with Rosetta
enabled: `colima delete`, then `colima start --vz-rosetta` with the flags above.
`colima delete` wipes all images and volumes.
