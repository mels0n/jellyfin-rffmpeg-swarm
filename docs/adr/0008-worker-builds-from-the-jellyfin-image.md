# 8. Build the worker from the same Jellyfin image as the server

Status: Accepted
Date: 2026-11-04

## Context
The worker was a plain `debian:bookworm` image that installed `jellyfin-ffmpeg7` from the
Jellyfin apt repository, while the server image is built from `jellyfin/jellyfin`. The
server's base has been Debian Trixie since Jellyfin 12.x, and with 12.4 it carries
`jellyfin-ffmpeg` 8. The server then began passing options that FFmpeg 7.1.4 does not know
(`-readrate_catchup`), so jobs carrying them failed on the workers with exit code 8. The server decides the FFmpeg arguments, so the FFmpeg that executes them has
to be the one the server was built for.

## Decision
Build the worker `FROM docker.io/jellyfin/jellyfin:${JELLYFIN_VERSION}`, the same tag the
server uses, and add only what a worker needs on top (`sshd`, NFS client, locale, Intel
drivers). The worker's entrypoint replaces upstream's, so Jellyfin itself never starts; the
image is used for its `/usr/lib/jellyfin-ffmpeg` and the OS libraries it links against.
Nothing about the FFmpeg version or the Debian release is written in this repository.

## Alternatives rejected
- **Pin a `jellyfin-ffmpeg` package on a Debian base.** Reintroduces a second version
  number that must be moved in step with Jellyfin's, and drifts the first time upstream
  bumps the major without this repo noticing.
- **Copy `/usr/lib/jellyfin-ffmpeg` from the Jellyfin image onto a slim base.** The binary
  is tied to the shared libraries and `libc6` of the release it was built on, so a base
  that differs from upstream's fails in ways that are hard to see.
- **Resolve the package name and Debian codename in CI.** Works, but adds moving parts
  (repository lookups, build arguments) to track something the upstream image already
  states.

## Consequences
Server and worker carry the same FFmpeg and the same OS when both are built from the same
Jellyfin release and deployed together, and a new Jellyfin release needs no change here.
The two images are built and pinned separately, so a deploy moves both pins in one change;
the `org.opencontainers.image.version` label on each image shows which release it was
built from. The worker image is larger because it also carries the unused
Jellyfin server and web files. The worker's base is now Trixie, so the Intel install-or-skip
check from [ADR-0004](0004-intel-driver-install-or-skip.md) skips the pinned bundle on its
own, as it does on the server.
