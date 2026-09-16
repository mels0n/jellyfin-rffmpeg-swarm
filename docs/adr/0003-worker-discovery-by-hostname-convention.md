# 3. Discover workers by hostname convention, not service DNS

Status: Accepted
Date: 2026-07-17

## Context
rffmpeg keeps an explicit host list, so something has to add workers as they are scaled up
and remove them as they die. A rewrite that resolved `tasks.<service>` via Swarm DNS
shipped with the service name baked in as a default; the private stack names its service
differently, so discovery resolved zero hosts and every transcode silently fell back to
running on the Jellyfin container itself. Playback kept working, which is exactly why it
went unnoticed.

## Decision
Derive the worker hostname prefix from the server's own hostname and walk the slot
hostnames (`jellyfin-transcode-1`, `-2`, ...) that Swarm assigns from the stack file's
`hostname: "jellyfin-transcode-{{.Task.Slot}}"` template. Probe each over SSH - the
transport rffmpeg actually uses - and stop only after `MAX_CONSECUTIVE_GAPS` consecutive
slots that are both unreachable and unknown.

## Alternatives rejected
- **`tasks.<service>` DNS.** Couples discovery to a service name the operator is free to
  choose, and the failure mode is silent.
- **Ping instead of SSH.** A worker whose `sshd` has died still answers ping and would be
  registered.
- **A fixed replica count in config.** One more thing to keep in sync with
  `docker service scale`.

## Consequences
Discovery needs no configuration at any replica count, and works regardless of what the
worker service is named. It does depend on the `hostname:` template staying in the stack
file. A registration survives container replacement because Swarm DNS keeps resolving the
slot hostname to the replacement task. Verify with `rffmpeg status`: a healthy pool lists
the worker hostnames, not just `localhost (fallback)`.
