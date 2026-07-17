#!/bin/bash
# Health check for rffmpeg-worker, run by the Docker HEALTHCHECK.
# Swarm replaces the task after consecutive failures; interval/timeout/retries
# and start_period are tuned in the stack file, not here.
#
# Design (2026-07-17, born from the NAS LAG incident):
# - Per-mount statfs with a generous timeout: a genuinely hung hard NFS mount
#   blocks far longer than any timeout, while brief congestion nearly always
#   answers within a few seconds. The old check (timeout 2 df -h across ALL
#   mounts) executed healthy workers during transient congestion and could not
#   say which mount was at fault.
# - Escalation-only write probe: no steady-state write I/O. Only after a
#   statfs failure do we probe further, to distinguish a statfs quirk from a
#   real dead mount and leave a diagnostic trail in the health log
#   (docker inspect --format '{{json .State.Health}}' <container>).

STATUS=0

for m in /media /transcodes /cache; do
  if timeout 10 stat -f "$m" >/dev/null 2>&1; then
    continue
  fi
  echo "UNHEALTHY: statfs on $m failed or timed out (>10s)"
  STATUS=1
  # Escalation probe, diagnostics only. /media is mounted read-only.
  if [ "$m" = "/media" ]; then
    if timeout 10 ls "$m" >/dev/null 2>&1; then
      echo "  escalation: directory listing on $m still works (statfs-only failure)"
    else
      echo "  escalation: $m is unreadable"
    fi
  else
    probe="$m/.healthprobe-$(hostname)"
    if timeout 10 bash -c "echo x > '$probe' && rm -f '$probe'" 2>/dev/null; then
      echo "  escalation: write probe on $m succeeded (statfs-only failure)"
    else
      echo "  escalation: write probe on $m failed"
    fi
  fi
done

# GPU check: the device node can disappear or lose permissions after driver or
# firmware hiccups; a worker without its GPU produces failed hw transcodes.
if [ -e /dev/dri/renderD128 ]; then
  if ! head -c 0 /dev/dri/renderD128 >/dev/null 2>&1; then
    echo "UNHEALTHY: GPU device /dev/dri/renderD128 unreadable"
    STATUS=1
  fi
fi

exit $STATUS
