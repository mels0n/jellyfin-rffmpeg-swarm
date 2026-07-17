#!/bin/bash
# rffmpeg-discovery.sh - continuous worker discovery daemon.
#
# Discovery is by HOSTNAME CONVENTION, derived from the server's own
# hostname - no configuration, any replica count (the proven design of the
# original rffmpeg-hostscale.sh):
#   server "jellyfin-server"     -> workers "jellyfin-transcode-1", -2, ...
#   server "jellyfin-server-dev" -> workers "jellyfin-transcode-dev-1", ...
# Slot hostnames come from the stack file's hostname template
# ("jellyfin-transcode-{{.Task.Slot}}") and are resolvable via Swarm DNS
# only while that slot's task is running, so registration by hostname stays
# valid across container replacement with no re-discovery.
#
# Each pass walks slots 1..N with no upper bound: the walk continues while
# slots are healthy OR known (registered in rffmpeg / tracked in the state
# file - a crashed mid-fleet slot must not end the walk), and stops only
# after MAX_CONSECUTIVE_GAPS consecutive slots that are both unreachable
# and unknown, i.e. past the real end of the fleet.
#
# The probe is SSH, not ping: SSH is what rffmpeg actually uses, and a
# worker that answers ping with a dead sshd must not be registered.
# Reconciliation: healthy hostnames are added; daemon-managed hostnames
# unhealthy for REMOVE_AFTER_MISSES passes are removed. The state file only
# tracks hosts THIS daemon added - manually registered hosts are never
# touched. State lives in /run, matching the rffmpeg DB lifecycle: both
# reset on container start.
#
# SSH identity/host-key options come from /etc/ssh/ssh_config (set in the
# Dockerfile); only probe-specific flags are passed here.

DISCOVERY_INTERVAL="${DISCOVERY_INTERVAL:-30}"
REMOVE_AFTER_MISSES="${REMOVE_AFTER_MISSES:-2}"
MAX_CONSECUTIVE_GAPS="${MAX_CONSECUTIVE_GAPS:-2}"
STATE_FILE="${STATE_FILE:-/run/rffmpeg/discovered_hosts}"
RFFMPEG_BIN="${RFFMPEG_BIN:-/usr/local/bin/rffmpeg}"
SSH_USER="${SSH_USER:-transcodessh}"

# Derive the worker hostname prefix from this server's own hostname.
if [[ "$(hostname)" == *"-dev" ]]; then
  WORKER_PREFIX="jellyfin-transcode-dev-"
else
  WORKER_PREFIX="jellyfin-transcode-"
fi

log() {
  echo "$(date '+%Y-%m-%d %H:%M:%S') [discovery] $1"
}

# Probe a worker over SSH. Succeeds only if the hostname resolves, sshd
# answers, and our key is accepted. ConnectTimeout bounds connection
# establishment; ServerAliveInterval/ServerAliveCountMax bound a
# post-connect stall so a worker that completes the handshake and then
# hangs cannot stall the walk.
probe_worker() {
  ssh -o BatchMode=yes -o ConnectTimeout=3 -o ServerAliveInterval=3 -o ServerAliveCountMax=2 "$SSH_USER@$1" true >/dev/null 2>&1
}

is_registered() {
  "$RFFMPEG_BIN" status | grep -wq "$1"
}

# One reconcile cycle. Reads and rewrites STATE_FILE
# (lines: "<hostname> <consecutive-miss-count>").
run_pass() {
  local host count slot gaps

  local -A misses=()
  if [[ -f "$STATE_FILE" ]]; then
    while read -r host count; do
      [[ -n "$host" ]] && misses["$host"]="${count:-0}"
    done < "$STATE_FILE"
  fi

  # Walk the slot hostnames.
  local -A healthy=()
  slot=1
  gaps=0
  while true; do
    host="${WORKER_PREFIX}${slot}"
    if probe_worker "$host"; then
      healthy["$host"]=1
      gaps=0
    elif is_registered "$host" || [[ -n "${misses[$host]:-}" ]]; then
      # Known slot that is currently unreachable: not the end of the
      # fleet. The miss counter below handles its removal.
      gaps=0
    else
      (( gaps++ ))
      if (( gaps >= MAX_CONSECUTIVE_GAPS )); then
        break
      fi
    fi
    (( slot++ ))
  done

  for host in "${!healthy[@]}"; do
    if ! is_registered "$host"; then
      if "$RFFMPEG_BIN" add "$host"; then
        log "added $host"
      else
        log "ERROR: rffmpeg add $host failed"
        continue
      fi
    fi
    misses["$host"]=0
  done

  for host in "${!misses[@]}"; do
    if [[ -z "${healthy[$host]:-}" ]]; then
      count=$(( ${misses[$host]} + 1 ))
      if (( count >= REMOVE_AFTER_MISSES )); then
        if "$RFFMPEG_BIN" remove "$host"; then
          log "removed $host after $count consecutive missed passes"
          unset "misses[$host]"
        else
          log "ERROR: rffmpeg remove $host failed; will retry next pass"
          misses["$host"]=$count
        fi
      else
        misses["$host"]=$count
      fi
    fi
  done

  mkdir -p "$(dirname "$STATE_FILE")"
  : > "$STATE_FILE"
  for host in "${!misses[@]}"; do
    echo "$host ${misses[$host]}" >> "$STATE_FILE"
  done
}

main() {
  log "starting worker discovery (prefix=$WORKER_PREFIX interval=${DISCOVERY_INTERVAL}s remove_after=$REMOVE_AFTER_MISSES misses)"
  while true; do
    run_pass
    sleep "$DISCOVERY_INTERVAL"
  done
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main
fi
