# 6. Publish a moving tag per branch, and drop the unstable image

Status: Accepted
Date: 2026-09-15

## Context
CI published a stable image and a second "unstable" image from the same Dockerfiles. The
unstable image was no longer wanted. Separately, `docker-compose.yml` pulled
`...-server:latest` - a tag nothing had ever published, so the documented deployment could
not have worked for anyone following the README.

## Decision
One image per service per branch: `main` publishes `:<version>` and `:latest`, `dev`
publishes `:<version>-dev` and `:dev`.

## Alternatives rejected
- **Version tags only.** Leaves the compose files with nothing stable to reference.
- **Keeping a separate pre-release image.** The workflow's `version` input covers testing a
  pre-release on the `dev` branch without a second permanent tag to maintain.

## Consequences
The compose files work as documented. A moving tag means `docker service update --force`
is enough to pick up a new build, and it also means production should pin a version or
digest instead - which the private stack already does. Each rebuild orphans the previous
digest behind the moving tag; the existing *Cleanup Untagged Images* workflow prunes those
weekly.
