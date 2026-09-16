# Architecture Decision Records

Five sentences each: context, decision, alternatives rejected, consequences. Numbered,
immutable once accepted - superseded by a new record rather than edited.

| # | Decision |
| --- | --- |
| [0001](0001-distribute-transcoding-with-rffmpeg-on-swarm.md) | Distribute transcoding with rffmpeg on Docker Swarm |
| [0002](0002-embedded-nfs-server.md) | Run the NFS server inside the Jellyfin container |
| [0003](0003-worker-discovery-by-hostname-convention.md) | Discover workers by hostname convention, not service DNS |
| [0004](0004-intel-driver-install-or-skip.md) | Install Intel drivers only when newer, never downgrade |
| [0005](0005-track-upstream-jellyfin-releases.md) | Resolve the Jellyfin version from upstream, not from a file |
| [0006](0006-image-tagging-scheme.md) | Publish a moving tag per branch, and drop the unstable image |
