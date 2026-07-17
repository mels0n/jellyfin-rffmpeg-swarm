#!/bin/bash
# rffmpeg-discovery.sh - continuous worker discovery daemon.
#
# Replaces the old 15-minute cron ping-probe (rffmpeg-hostscale.sh).
# Each pass:
#   1. Resolve all running worker task IPs in one Swarm DNS lookup
#      (tasks.<service> DNS round-robin returns only RUNNING tasks, so
#      pending/failed slots never create discovery holes).
#   2. SSH-probe each IP and ask the worker its slot-stable hostname.
#      SSH is the probe because SSH is what rffmpeg actually uses: a
#      worker that answers ping but whose sshd is down must not be added.
#   3. Reconcile with the rffmpeg host DB: add healthy hostnames, remove
#      daemon-managed hostnames unhealthy for REMOVE_AFTER_MISSES passes.
#
# The state file only tracks hosts THIS daemon added. Hosts registered
# manually (rffmpeg add by hand) are never touched. State lives in /run,
# which matches the rffmpeg DB lifecycle: both reset on container start.
#
# SSH identity/host-key options come from /etc/ssh/ssh_config (set in the
# Dockerfile); only probe-specific flags are passed here.

WORKER_TASKS_DNS="${WORKER_TASKS_DNS:-tasks.transcode-worker}"
DISCOVERY_INTERVAL="${DISCOVERY_INTERVAL:-30}"
REMOVE_AFTER_MISSES="${REMOVE_AFTER_MISSES:-2}"
STATE_FILE="${STATE_FILE:-/run/rffmpeg/discovered_hosts}"
RFFMPEG_BIN="${RFFMPEG_BIN:-/usr/local/bin/rffmpeg}"
SSH_USER="${SSH_USER:-transcodessh}"

log() {
  echo "$(date '+%Y-%m-%d %H:%M:%S') [discovery] $1"
}

# All IPs of currently RUNNING worker tasks, one per line.
discover_ips() {
  getent hosts "$WORKER_TASKS_DNS" | awk '{print $1}' | sort -u
}

# Probe a worker over SSH and print its slot-stable hostname.
# Fails (nonzero) if sshd is unreachable or not accepting our key.
# ConnectTimeout only bounds connection establishment; ServerAliveInterval/
# ServerAliveCountMax bound a post-connect stall so a worker that completes
# the handshake and then hangs can't stall the serial probe loop.
probe_hostname() {
  ssh -o BatchMode=yes -o ConnectTimeout=3 -o ServerAliveInterval=3 -o ServerAliveCountMax=2 "$SSH_USER@$1" hostname 2>/dev/null
}

is_registered() {
  "$RFFMPEG_BIN" status | grep -wq "$1"
}

# One reconcile cycle. Reads and rewrites STATE_FILE
# (lines: "<hostname> <consecutive-miss-count>").
run_pass() {
  local ip host

  local -A healthy=()
  while read -r ip; do
    [[ -z "$ip" ]] && continue
    if host=$(probe_hostname "$ip") && [[ -n "$host" ]]; then
      healthy["$host"]=1
    else
      log "worker at $ip did not answer SSH probe; skipping"
    fi
  done < <(discover_ips)

  local -A misses=()
  local count
  if [[ -f "$STATE_FILE" ]]; then
    while read -r host count; do
      [[ -n "$host" ]] && misses["$host"]="${count:-0}"
    done < "$STATE_FILE"
  fi

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
  log "starting worker discovery (dns=$WORKER_TASKS_DNS interval=${DISCOVERY_INTERVAL}s remove_after=$REMOVE_AFTER_MISSES misses)"
  while true; do
    run_pass
    sleep "$DISCOVERY_INTERVAL"
  done
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main
fi
