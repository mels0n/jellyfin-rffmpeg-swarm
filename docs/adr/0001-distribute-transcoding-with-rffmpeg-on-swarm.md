# 1. Distribute transcoding with rffmpeg on Docker Swarm

Status: Accepted
Date: 2026-07-17 (recorded retroactively 2026-09-15)

## Context
A single mini-PC cannot serve the number of simultaneous transcodes this household
needs, but several mini-PCs were already on hand. Jellyfin has no native concept of a
transcode cluster: it shells out to a local `ffmpeg` binary.

## Decision
Run Jellyfin unmodified and replace its `ffmpeg` binary with
[rffmpeg](https://github.com/joshuaboniface/rffmpeg), which dispatches the same command
line to a remote host over SSH. Workers are plain containers running `sshd` plus
`jellyfin-ffmpeg`, scaled as Docker Swarm replicas.

## Alternatives rejected
- **A bigger single server.** Does not use hardware already owned, and caps out again.
- **Kubernetes.** Far more operational surface than a three-to-five node home cluster
  justifies.
- **Patching Jellyfin.** Would have to be re-applied against every upstream release;
  rffmpeg needs no fork.

## Consequences
Scaling is `docker service scale`. Every worker must present the *same* filesystem paths
as the server, which is what forces the NFS design in [ADR-0002](0002-embedded-nfs-server.md).
Transcoding is only as reliable as SSH reachability, which is what
[ADR-0003](0003-worker-discovery-by-hostname-convention.md) addresses.
