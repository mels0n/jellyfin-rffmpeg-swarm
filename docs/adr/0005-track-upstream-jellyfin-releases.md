# 5. Resolve the Jellyfin version from upstream, not from a file in the repo

Status: Accepted
Date: 2026-09-15

## Context
`versions.env` held the Jellyfin version to build. That made sense while a human chose the
version. Once the goal became "publish a new image when Jellyfin publishes a new release",
the file was a cached copy of state that exists authoritatively elsewhere, plus a
commit-back step to keep the cache in sync - and a cache that can drift.

## Decision
Delete the file. Resolve the newest stable release from the Docker Hub tag list for
`jellyfin/jellyfin` at build time, and ask GHCR whether that version has already been
built.

## Alternatives rejected
- **Keep the file and have a bot bump it.** Needs a PAT, because a commit pushed with
  `GITHUB_TOKEN` deliberately does not trigger another workflow run - and it still leaves
  the file to drift.
- **Renovate or Dependabot.** Another integration to install and authorize for one value.
- **GitHub Releases as the source.** The build consumes a Docker tag, so the tag list is
  the thing that actually has to exist.

## Consequences
Nothing in the repo records a version, so nothing can go stale. A new Jellyfin release is
published automatically within a day, including a major bump - deliberate, and safe here
only because deployments pin a version or digest rather than following `:latest`. The tag
filter (`X.Y` / `X.Y.Z`) is what keeps `rc`, `preview`, `unstable` and the dated per-build
tags out; a pre-release can still be built on demand via the workflow's `version` input.
