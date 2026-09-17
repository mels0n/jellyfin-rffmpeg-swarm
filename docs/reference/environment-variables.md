# Environment Variables

Every variable the two images read, with the value that applies when it is not set.
Nothing here needs to be set for a normal deployment; the defaults are the supported path.

## jellyfin-server

### NFS exports

| Variable | Default | Purpose |
| --- | --- | --- |
| `NFS_EXPORT_0`, `NFS_EXPORT_1`, ... | none | One `/etc/exports` line each. The stack file sets `/transcodes` (`fsid=1`) and `/cache` (`fsid=2`). Each export needs a **unique `fsid=`** or NFSv4 refuses to start. |
| `NFS_LOG_LEVEL` | `INFO` | `DEBUG` for verbose NFS logging. |
| `NFS_SERVER_THREAD_COUNT` | one per CPU | `rpc.nfsd` thread count. Must be a positive integer; the entrypoint refuses to start otherwise. |
| `NFS_DISABLE_VERSION_3` | unset | Any non-empty value drops NFSv3 from nfsd, mountd and statd, leaving v4 only. The workers mount with v4, so this is safe to set. |
| `NFS_ENABLE_KERBEROS` | unset | Only consulted at shutdown, where it terminates `rpc.svcgssd`. Nothing starts that daemon, so setting this has no effect. |

`NFS_VERSION`, `NFS_PORT`, `NFS_PORT_MOUNTD`, `NFS_PORT_STATD_IN`, `NFS_PORT_STATD_OUT`,
`NFS_ENABLE_NFSDCLD` and `NFS_NFSDCLD_STORAGE_DIR` are declared as names in `entrypoint.sh`
but never read. The built-in values always apply: NFS 4.2 on port 2049, mountd 32767,
statd 32765 in / 32766 out, no nfsdcld.

### Worker discovery

Read by `rffmpeg-discovery.sh`. Discovery derives everything else from the server's own
hostname, so there is nothing to configure at any replica count.

| Variable | Default | Purpose |
| --- | --- | --- |
| `DISCOVERY_INTERVAL` | `30` | Seconds between reconcile passes. |
| `REMOVE_AFTER_MISSES` | `2` | Consecutive failed passes before a daemon-added host is removed. |
| `MAX_CONSECUTIVE_GAPS` | `2` | Consecutive slots that are both unreachable *and* unknown before the walk decides it has passed the end of the fleet. |
| `SSH_USER` | `transcodessh` | User the SSH probe connects as. Must match the worker. |
| `RFFMPEG_BIN` | `/usr/local/bin/rffmpeg` | Path to the rffmpeg binary. |
| `STATE_FILE` | `/run/rffmpeg/discovered_hosts` | Tracks only hosts *this daemon* added, so manually added hosts are never touched. Lives in `/run`, so it resets on container start in step with the rffmpeg database. |

### General

| Variable | Default | Purpose |
| --- | --- | --- |
| `TZ` | container default (UTC) | Timezone, e.g. `America/Chicago`. |
| `UMASK` | `002` | Applied to files the server creates. |

## transcode-worker

The worker takes no configuration. Two values are derived at start-up rather than set:

- **NFS server hostname** - `jellyfin-server`, or `jellyfin-server-dev` when the worker's
  own hostname marks it as a dev-stack worker. It mounts `/transcodes` and `/cache` from
  there via `/etc/fstab` (`rw,nolock,actimeo=1`).
- **Slot hostname** - assigned by Swarm from the stack file's
  `hostname: "jellyfin-transcode-{{.Task.Slot}}"` template. Discovery depends on this
  template; see [ADR-0003](../adr/0003-worker-discovery-by-hostname-convention.md).

## Build arguments

| Argument | Default | Purpose |
| --- | --- | --- |
| `RFFMPEG_URL` | `https://raw.githubusercontent.com/joshuaboniface/rffmpeg/master/rffmpeg` | Where the server image fetches the `rffmpeg` script from at build time. Server image only. |
| `JELLYFIN_VERSION` | `latest` | Jellyfin release to build against. CI always passes the version it resolved from upstream; the default only applies to a local `docker build` with no `--build-arg`. |
| `IGC_VERSION`, `NEO_VERSION`, `GMM_VERSION`, `LEVEL_ZERO_VERSION` | pinned in the Dockerfiles | The Intel compute-runtime release train. Installed only when newer than what the base image already has - see [ADR-0004](../adr/0004-intel-driver-install-or-skip.md). |
