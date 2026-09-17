# Working in jellyfin-rffmpeg-swarm

This file is for anyone (or any tool) making changes to this repository. It
covers how to build and check the code and which decisions are already settled.
It does not restate the README.

## What this is

Two Docker images (`jellyfin-rffmpeg-server`, `rffmpeg-worker`) plus the Swarm
stack files that run them. Everything is shell and Dockerfiles. Each image has
its own build context directory, and Docker cannot reach outside it, so anything
shared between server and worker is duplicated on purpose. Keep the two copies in
step rather than trying to factor them out.

## Build and check

- Server image: `docker build --build-arg JELLYFIN_VERSION=<tag> -t jellyfin-rffmpeg-server ./jellyfin-rffmpeg-server`
- Worker image: `docker build --build-arg JELLYFIN_VERSION=<tag> -t rffmpeg-worker ./rffmpeg-worker`
- Local stack: `docker compose -f docker-compose.dev.yml up`
- `tests/test-discovery.sh` is stale and fails. It stubs a `getent` lookup the
  discovery daemon no longer performs (see ADR-0003). Nothing runs it in CI. Fix
  the harness before trusting it as a regression gate.

`JELLYFIN_VERSION` defaults to `latest`. CI resolves the newest stable
`jellyfin/jellyfin` tag from Docker Hub and passes it explicitly; do the same
when reproducing a CI build locally.

## Read the ADRs before changing behaviour

`docs/adr/` records the decisions whose "obvious" alternative is wrong. In
particular:

- **0003**: worker discovery is by hostname convention, not `tasks.<service>`
  DNS. The DNS version failed silently, with playback still working.
- **0004**: Intel drivers are install-or-skip. Never add `--allow-downgrades`,
  and never pin a driver version without checking it against what the base
  image already ships.
- **0005**: there is no version file. The Jellyfin version is resolved from
  upstream at build time. Do not reintroduce `versions.env`.

Any new non-obvious choice gets its own numbered ADR in the same directory.

## CI

`.github/workflows/docker-publish.yml` builds both images. It resolves the
newest stable `jellyfin/jellyfin` tag from Docker Hub and asks GHCR whether that
version is already built, so a scheduled run is a no-op until Jellyfin ships
something new. Pushing to `main` publishes `:<version>` and `:latest`; pushing to
`dev` publishes `:<version>-dev` and `:dev`.

`.github/workflows/repo-hygiene.yml` fails if local-only working files are ever
tracked or if a public document references internal tooling.

## Gotchas

- **Line endings.** Windows checkouts typically run with `core.autocrlf=true`
  and there is no `.gitattributes`. Editing a Dockerfile with a tool that
  rewrites the whole file makes the working tree CRLF; the index stays LF, so CI
  is fine. Verify with `git ls-files --eol` rather than reacting to the
  working-tree state.
- **Deploys are not automatic.** Publishing an image does not move any node. A
  production stack should pin `:<version>@sha256:...`, so it only moves when its
  stack file does.
