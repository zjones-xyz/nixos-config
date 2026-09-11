# memory-alpha — manual steps

## 1. Dockge decommission (on the hardware, after switching)

Arcane already manages the stacks tree Dockge used to; this cleans up what
the flake switch cannot reach itself.

1. [ ] `nixos-rebuild switch` — removing the unit stops it, and the old
   unit's `ExecStop` runs `docker compose down`, taking the container with
   it. If one lingers: `docker rm -f dockge`.
2. [ ] `docker compose ls` — any project whose config path still points
   under `/opt/stacks/` gets one redeploy from Arcane. Expect a container
   recreate, not an error: the compose working-dir label changes from the
   symlinked path to the real one.
3. [ ] `sudo rm /opt/stacks && sudo rmdir /opt` (if otherwise empty) — the
   tmpfiles symlink outlives the rule that created it.
4. [ ] `rm -rf /home/z/dockge` once satisfied nothing in it is wanted.
