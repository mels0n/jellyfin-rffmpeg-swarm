# CLAUDE.md - jellyfin-rffmpeg-swarm

Repo-specific facts only. The global standards apply and are not restated here.

## What this is
Two Docker images (`jellyfin-rffmpeg-server`, `rffmpeg-worker`) plus the Swarm stack files
that run them. Shell and Dockerfiles - no TypeScript, so the FSD layer rules and
`dependency-cruiser` gate do not apply here. The equivalent structural boundary is the
image boundary: anything shared between server and worker is duplicated deliberately,
because each build context is a separate directory and Docker cannot reach outside it.

## Read the ADRs before changing behaviour
`docs/adr/` records the decisions whose "obvious" alternative is wrong. In particular:
- **0003** - worker discovery is by hostname convention, NOT `tasks.<service>` DNS. The
  DNS version failed silently, with playback still working.
- **0004** - Intel drivers are install-or-skip. Never add `--allow-downgrades`, and never
  pin a driver version without checking it against what the base image already ships.
- **0005** - there is no version file. The Jellyfin version is resolved from upstream at
  build time. Do not reintroduce `versions.env`.

## CI
`.github/workflows/docker-publish.yml` builds both images. It resolves the newest stable
`jellyfin/jellyfin` tag from Docker Hub and asks GHCR whether that version is already
built, so a scheduled run is a no-op until Jellyfin ships something new. Pushing to `main`
publishes `:<version>` + `:latest`; `dev` publishes `:<version>-dev` + `:dev`.

## Gotchas
- **Line endings.** `core.autocrlf=true` on the Windows checkout, no `.gitattributes`.
  Editing a Dockerfile with a tool that rewrites the whole file makes the working tree
  CRLF; the index stays LF, so CI is fine. Verify with `git ls-files --eol` rather than
  reacting to the working-tree state.
- **`tests/test-discovery.sh` is stale** and fails: it stubs a `getent` lookup the daemon
  no longer performs (see ADR-0003). Nothing runs it in CI. Fix the harness before
  trusting it as a regression gate.
- **Deploys are not automatic.** Publishing an image does not move any node. The private
  media-suite stack pins `:<version>@sha256:...`, so it only moves when its stack file
  does.
