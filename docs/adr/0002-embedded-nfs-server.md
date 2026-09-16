# 2. Run the NFS server inside the Jellyfin container

Status: Accepted
Date: 2026-07-17 (recorded retroactively 2026-09-15)

## Context
A worker writes transcoded segments to a path such as `/transcodes/xyz.ts`, and the
Jellyfin server must then read that exact path to serve the client. The two processes are
on different hosts, so the path has to mean the same thing on both.

## Decision
Export `/transcodes` and `/cache` over NFS from inside the `jellyfin-server` container,
and have every worker mount them at the identical paths.

## Alternatives rejected
- **An external NFS share on the NAS.** Turns transcoding into a read-from-NAS,
  write-to-NAS, read-from-NAS cycle, putting sustained transcode I/O on the array that is
  also serving the source media.
- **A shared cluster filesystem (Ceph, GlusterFS).** Disproportionate operational weight
  for two scratch directories.

## Consequences
Transcode scratch I/O lands on the server's local NVMe instead of the NAS. Workers need
`cap_add: [SYS_ADMIN]` to mount, and AppArmor must be disabled on every host, both of
which are real security concessions documented in
[the node setup how-to](../how-to/manual-node-setup.md). Each export needs a unique
`fsid=` or NFSv4 refuses to start.
