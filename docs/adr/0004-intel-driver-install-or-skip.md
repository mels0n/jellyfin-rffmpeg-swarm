# 4. Install Intel drivers only when newer, never downgrade

Status: Accepted
Date: 2026-09-15

## Context
Both images side-loaded a pinned Intel compute-runtime release (24.35.30872.22) because
Debian Bookworm's `libc6` is older than the 2.38 that 25.x requires. When the server image
moved to Jellyfin 12.x its base became Debian Trixie, which already ships
`intel-opencl-icd` 26.31.39395.13. The pinned install was therefore *downgrading* the base
image's drivers by roughly two years and pinning the result with `apt-mark`, and the
download step was the build's only recurring flake.

## Decision
Treat the five packages as one matched release train and install them only when they are
newer than what is already present, checking before anything is downloaded.

## Alternatives rejected
- **Per-package comparison.** Could leave a mixed set - a new OpenCL runtime beside an old
  Level Zero - which is a worse failure mode than either version alone.
- **Deleting the block from the server image.** Correct today, but silently wrong again if
  a future base ships without drivers.
- **Bumping the pin to 25.x/26.x.** Breaks the worker, which is still Bookworm.

## Consequences
The server skips the block entirely and keeps its base drivers, costing zero network in
the step that used to fail. The worker still installs the full set. The check is
self-correcting: when the worker's base moves to Trixie it starts skipping on its own.
Build logs print `Intel bundle SKIPPED: <pkg> <have> is already >= <want>` when it skips.
