# Worker Discovery Daemon Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the 15-minute cron ping-probe worker discovery with a continuous daemon that discovers workers via Swarm DNS (`tasks.<service>`), verifies them with an SSH probe, and reconciles the rffmpeg host list every ~30 seconds — eliminating the up-to-15-minute zero-worker window after every server restart.

**Architecture:** A new bash daemon (`rffmpeg-discovery.sh`) runs inside the `jellyfin-server` container, launched from the entrypoint right after `rffmpeg init` (before Jellyfin starts). Each pass it: (1) resolves all running worker task IPs in one `getent hosts tasks.transcode-worker` lookup, (2) SSH-probes each IP and asks the worker its slot-stable hostname (`ssh transcodessh@<ip> hostname`), (3) adds healthy hostnames to rffmpeg and removes daemon-managed hostnames that have been unhealthy for 2 consecutive passes. A state file in `/run` tracks which hosts the daemon added, so it never removes hosts a user registered manually. The old `rffmpeg-hostscale.sh` and its cron entry are deleted; the midnight `rffmpeg clear` cron entry stays.

**Tech Stack:** Bash, Docker Swarm DNS (`tasks.<service>` DNS-RR), OpenSSH client, rffmpeg CLI. Tests are plain bash with PATH-shim stubs (runnable in Git Bash on Windows or any Linux).

## Global Constraints

- Never `git push` — Chris pushes manually (global rule for project repos).
- Work on a feature branch `feature/worker-discovery-daemon` off `main`.
- The server container's `/etc/ssh/ssh_config` already sets `IdentityFile /run/rffmpeg/.ssh/id_rsa`, `StrictHostKeyChecking no`, `UserKnownHostsFile /dev/null` (see `jellyfin-rffmpeg-server/Dockerfile:131-135`) — the probe must NOT duplicate those flags, only add `-o BatchMode=yes -o ConnectTimeout=3`.
- SSH user on workers is `transcodessh` (uid 7001). rffmpeg state DB lives at `/rffmpeg/rffmpeg.db` and is ephemeral (not a volume) — the daemon must converge from an empty DB with no manual input.
- Both prod and dev stacks name the worker service `transcode-worker` (separate stacks/networks), so the default DNS name `tasks.transcode-worker` is correct for both. All dev/prod hostname-prefix sniffing in the old script is deleted, not ported.
- Env var contract (all optional, defaults in script): `WORKER_TASKS_DNS` (default `tasks.transcode-worker`), `DISCOVERY_INTERVAL` (default `30`), `REMOVE_AFTER_MISSES` (default `2`).
- No em-dash rule does not apply (this is not client-facing copy), but keep README style consistent with the existing file.

---

## File Structure

- Create: `jellyfin-rffmpeg-server/rffmpeg-discovery.sh` — the daemon. Pure functions (`discover_ips`, `probe_hostname`, `is_registered`, `run_pass`) plus a `main` loop guarded by `BASH_SOURCE` so tests can source it.
- Create: `tests/test-discovery.sh` — self-contained test harness with stub `getent`/`ssh`/`rffmpeg` commands on PATH.
- Delete: `jellyfin-rffmpeg-server/rffmpeg-hostscale.sh`
- Modify: `jellyfin-rffmpeg-server/Dockerfile` (COPY + chmod + crontab lines)
- Modify: `jellyfin-rffmpeg-server/entrypoint.sh` (launch daemon after rffmpeg init)
- Modify: `docker-compose.yml`, `docker-compose.dev.yml` (commented env-var documentation)
- Modify: `README.md` (architecture bullet + new discovery subsection)

---

### Task 1: Discovery script with reconcile logic (TDD)

**Files:**
- Create: `tests/test-discovery.sh`
- Create: `jellyfin-rffmpeg-server/rffmpeg-discovery.sh`

**Interfaces:**
- Produces: `rffmpeg-discovery.sh` sourceable with functions `discover_ips` (stdout: one IP per line), `probe_hostname IP` (stdout: worker hostname, exit nonzero on failure), `is_registered HOSTNAME` (exit code), `run_pass` (one reconcile cycle), `main` (infinite loop). Env vars: `WORKER_TASKS_DNS`, `DISCOVERY_INTERVAL`, `REMOVE_AFTER_MISSES`, `STATE_FILE`, `RFFMPEG_BIN`, `SSH_USER` — all with defaults.
- Consumes: nothing from other tasks.

- [ ] **Step 1: Create branch**

```bash
git checkout -b feature/worker-discovery-daemon
```

- [ ] **Step 2: Write the failing test harness**

Create `tests/test-discovery.sh` with this exact content:

```bash
#!/bin/bash
# Test harness for jellyfin-rffmpeg-server/rffmpeg-discovery.sh
# Stubs getent/ssh/rffmpeg via a PATH shim directory. Runs on any bash
# (Git Bash on Windows included). No Docker or network needed.

set -u
TESTS_PASSED=0
TESTS_FAILED=0

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$REPO_ROOT/jellyfin-rffmpeg-server/rffmpeg-discovery.sh"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
STUB_BIN="$WORK/bin"
mkdir -p "$STUB_BIN"

# --- stubs ------------------------------------------------------------
# DNS stub: prints "IP NAME" lines from dns.txt (getent hosts format)
cat > "$STUB_BIN/getent" <<'EOF'
#!/bin/bash
cat "$STUB_STATE/dns.txt" 2>/dev/null
exit 0
EOF

# ssh stub: last arg is the remote command, arg before it is user@ip.
# Looks up the ip in ssh_map.txt ("IP HOSTNAME" lines); missing ip = dead.
cat > "$STUB_BIN/ssh" <<'EOF'
#!/bin/bash
target=""
for a in "$@"; do
  case "$a" in
    *@*) target="${a#*@}" ;;
  esac
done
host=$(awk -v ip="$target" '$1 == ip {print $2}' "$STUB_STATE/ssh_map.txt" 2>/dev/null)
if [ -n "$host" ]; then
  echo "$host"
  exit 0
fi
exit 255
EOF

# rffmpeg stub: persists registered hosts in rffmpeg_hosts.txt, logs calls
cat > "$STUB_BIN/rffmpeg" <<'EOF'
#!/bin/bash
cmd="$1"; shift || true
hosts_file="$STUB_STATE/rffmpeg_hosts.txt"
touch "$hosts_file"
case "$cmd" in
  status)
    echo "Hostname State"
    cat "$hosts_file"
    ;;
  add)
    echo "$1" >> "$hosts_file"
    echo "add $1" >> "$STUB_STATE/calls.log"
    ;;
  remove)
    grep -vw "$1" "$hosts_file" > "$hosts_file.tmp" || true
    mv "$hosts_file.tmp" "$hosts_file"
    echo "remove $1" >> "$STUB_STATE/calls.log"
    ;;
esac
exit 0
EOF
chmod +x "$STUB_BIN"/*

# --- helpers ----------------------------------------------------------
setup_case() {
  export STUB_STATE="$WORK/state-$1"
  mkdir -p "$STUB_STATE"
  : > "$STUB_STATE/dns.txt"
  : > "$STUB_STATE/ssh_map.txt"
  : > "$STUB_STATE/rffmpeg_hosts.txt"
  : > "$STUB_STATE/calls.log"
  export STATE_FILE="$STUB_STATE/discovered_hosts"
  export RFFMPEG_BIN="$STUB_BIN/rffmpeg"
  export PATH="$STUB_BIN:$PATH"
  # shellcheck disable=SC1090
  source "$SCRIPT"
}

assert() {
  local desc="$1"; shift
  if "$@"; then
    echo "PASS: $desc"
    TESTS_PASSED=$((TESTS_PASSED + 1))
  else
    echo "FAIL: $desc"
    TESTS_FAILED=$((TESTS_FAILED + 1))
  fi
}

registered() { grep -qw "$1" "$STUB_STATE/rffmpeg_hosts.txt"; }
not_registered() { ! registered "$1"; }

# --- test 1: two live workers get added -------------------------------
(
  setup_case t1
  {
    echo "10.0.0.2 tasks.transcode-worker"
    echo "10.0.0.3 tasks.transcode-worker"
  } > "$STUB_STATE/dns.txt"
  {
    echo "10.0.0.2 jellyfin-transcode-1"
    echo "10.0.0.3 jellyfin-transcode-2"
  } > "$STUB_STATE/ssh_map.txt"
  run_pass
  assert "live worker 1 added" registered jellyfin-transcode-1
  assert "live worker 2 added" registered jellyfin-transcode-2
  assert "state file tracks both" grep -qw jellyfin-transcode-1 "$STATE_FILE"
  exit $TESTS_FAILED
); TESTS_FAILED=$((TESTS_FAILED + $?))

# --- test 2: already-registered worker is not re-added ----------------
(
  setup_case t2
  echo "10.0.0.2 tasks.transcode-worker" > "$STUB_STATE/dns.txt"
  echo "10.0.0.2 jellyfin-transcode-1" > "$STUB_STATE/ssh_map.txt"
  run_pass
  run_pass
  adds=$(grep -c "^add jellyfin-transcode-1$" "$STUB_STATE/calls.log")
  assert "worker added exactly once across two passes" [ "$adds" -eq 1 ]
  exit $TESTS_FAILED
); TESTS_FAILED=$((TESTS_FAILED + $?))

# --- test 3: vanished worker removed after 2 missed passes ------------
(
  setup_case t3
  echo "10.0.0.2 tasks.transcode-worker" > "$STUB_STATE/dns.txt"
  echo "10.0.0.2 jellyfin-transcode-1" > "$STUB_STATE/ssh_map.txt"
  run_pass
  # worker's task is gone from DNS
  : > "$STUB_STATE/dns.txt"
  run_pass
  assert "still registered after 1 miss" registered jellyfin-transcode-1
  run_pass
  assert "removed after 2 misses" not_registered jellyfin-transcode-1
  exit $TESTS_FAILED
); TESTS_FAILED=$((TESTS_FAILED + $?))

# --- test 4: ssh-dead worker is never added ---------------------------
(
  setup_case t4
  echo "10.0.0.9 tasks.transcode-worker" > "$STUB_STATE/dns.txt"
  # no ssh_map entry: IP resolves in DNS but sshd is not answering
  run_pass
  assert "ssh-dead worker not added" not_registered jellyfin-transcode-9
  assert "no add calls made" [ ! -s "$STUB_STATE/calls.log" ]
  exit $TESTS_FAILED
); TESTS_FAILED=$((TESTS_FAILED + $?))

# --- test 5: manually-added host is never removed ---------------------
(
  setup_case t5
  # a host the user registered by hand: in rffmpeg, not in our state file
  echo "external-worker" > "$STUB_STATE/rffmpeg_hosts.txt"
  : > "$STUB_STATE/dns.txt"
  run_pass
  run_pass
  run_pass
  assert "manually-added host untouched" registered external-worker
  exit $TESTS_FAILED
); TESTS_FAILED=$((TESTS_FAILED + $?))

# --- test 6: recovery within grace period resets the miss counter -----
(
  setup_case t6
  echo "10.0.0.2 tasks.transcode-worker" > "$STUB_STATE/dns.txt"
  echo "10.0.0.2 jellyfin-transcode-1" > "$STUB_STATE/ssh_map.txt"
  run_pass
  : > "$STUB_STATE/dns.txt"          # miss 1
  run_pass
  echo "10.0.0.2 tasks.transcode-worker" > "$STUB_STATE/dns.txt"  # back
  run_pass
  : > "$STUB_STATE/dns.txt"          # miss 1 again (counter was reset)
  run_pass
  assert "recovered worker not removed on later single miss" registered jellyfin-transcode-1
  exit $TESTS_FAILED
); TESTS_FAILED=$((TESTS_FAILED + $?))

echo ""
if [ "$TESTS_FAILED" -eq 0 ]; then
  echo "ALL TESTS PASSED"
  exit 0
else
  echo "$TESTS_FAILED TEST(S) FAILED"
  exit 1
fi
```

- [ ] **Step 3: Run the tests to verify they fail**

Run: `bash tests/test-discovery.sh`
Expected: FAIL — every subshell errors because `jellyfin-rffmpeg-server/rffmpeg-discovery.sh` does not exist (source fails), nonzero exit.

- [ ] **Step 4: Write the discovery script**

Create `jellyfin-rffmpeg-server/rffmpeg-discovery.sh` with this exact content:

```bash
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
probe_hostname() {
  ssh -o BatchMode=yes -o ConnectTimeout=3 "$SSH_USER@$1" hostname 2>/dev/null
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
        "$RFFMPEG_BIN" remove "$host"
        log "removed $host after $count consecutive missed passes"
        unset "misses[$host]"
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
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `bash tests/test-discovery.sh`
Expected: `ALL TESTS PASSED`, exit 0. Also run a syntax check: `bash -n jellyfin-rffmpeg-server/rffmpeg-discovery.sh` — no output.

- [ ] **Step 6: Commit**

```bash
git add tests/test-discovery.sh jellyfin-rffmpeg-server/rffmpeg-discovery.sh
git commit -m "server: add continuous worker discovery daemon (DNS + SSH probe)"
```

---

### Task 2: Wire the daemon into the image; delete the cron mechanism

**Files:**
- Modify: `jellyfin-rffmpeg-server/Dockerfile:137-143`
- Modify: `jellyfin-rffmpeg-server/entrypoint.sh:513-519`
- Delete: `jellyfin-rffmpeg-server/rffmpeg-hostscale.sh`

**Interfaces:**
- Consumes: `/rffmpeg-discovery.sh` daemon from Task 1 (self-daemonizing `main` loop; safe to launch with `&`).
- Produces: image whose entrypoint starts discovery immediately after `rffmpeg init`/`clear`, before Jellyfin starts. Cron keeps ONLY the midnight `rffmpeg clear`.

- [ ] **Step 1: Update the Dockerfile COPY/cron block**

In `jellyfin-rffmpeg-server/Dockerfile`, replace lines 137-143:

```dockerfile
# Copies the container's operational scripts and sets up a cron job.
# The cron job periodically runs the host scaling script to discover and manage worker nodes.
COPY --chown=transcodessh:users rffmpeg-hostscale.sh /rffmpeg-hostscale.sh
COPY --chown=root:root entrypoint.sh /entrypoint.sh
COPY --chown=root:root recording-post-proceessing.sh /recording-post-processing.sh
RUN chmod +x /rffmpeg-hostscale.sh /entrypoint.sh /recording-post-processing.sh && \
    (crontab -l 2>/dev/null; echo "*/15 * * * * /rffmpeg-hostscale.sh"; echo "0 0 * * * /usr/local/bin/rffmpeg clear") | crontab -
```

with:

```dockerfile
# Copies the container's operational scripts.
# Worker discovery runs as a continuous daemon started by the entrypoint
# (rffmpeg-discovery.sh); cron only handles the nightly rffmpeg state clear.
COPY --chown=root:root rffmpeg-discovery.sh /rffmpeg-discovery.sh
COPY --chown=root:root entrypoint.sh /entrypoint.sh
COPY --chown=root:root recording-post-proceessing.sh /recording-post-processing.sh
RUN chmod +x /rffmpeg-discovery.sh /entrypoint.sh /recording-post-processing.sh && \
    (crontab -l 2>/dev/null; echo "0 0 * * * /usr/local/bin/rffmpeg clear") | crontab -
```

- [ ] **Step 2: Delete the old script**

```bash
git rm jellyfin-rffmpeg-server/rffmpeg-hostscale.sh
```

- [ ] **Step 3: Launch the daemon from the entrypoint**

In `jellyfin-rffmpeg-server/entrypoint.sh`, the rffmpeg init block currently ends at line 518-519:

```bash
# Initialize the rffmpeg database on first run, or clear it on subsequent runs.
if [ ! -f /rffmpeg/rffmpeg.db ]; then
    /usr/local/bin/rffmpeg init -y
else
    /usr/local/bin/rffmpeg clear
fi
#------
```

Replace that block with:

```bash
# Initialize the rffmpeg database on first run, or clear it on subsequent runs.
if [ ! -f /rffmpeg/rffmpeg.db ]; then
    /usr/local/bin/rffmpeg init -y
else
    /usr/local/bin/rffmpeg clear
fi

# Start the continuous worker discovery daemon. Started here (not cron) so
# workers are registered within seconds of container start: the rffmpeg DB
# is ephemeral, and without this every server restart would begin with an
# empty host list and transcode locally until discovery caught up.
/rffmpeg-discovery.sh &
echo "INFO: Worker discovery daemon started (PID $!)"
#------
```

- [ ] **Step 4: Verify syntax and build**

Run: `bash -n jellyfin-rffmpeg-server/entrypoint.sh` — expect no output.
If Docker is available locally, run: `docker build -t discovery-test ./jellyfin-rffmpeg-server` and expect a successful build (network fetches may be slow; if Docker is unavailable on this machine, skip the build and note it in the commit message — CI builds on push).

- [ ] **Step 5: Commit**

```bash
git add jellyfin-rffmpeg-server/Dockerfile jellyfin-rffmpeg-server/entrypoint.sh
git commit -m "server: start discovery daemon from entrypoint, drop 15-min cron probe"
```

---

### Task 3: Compose files and README documentation

**Files:**
- Modify: `docker-compose.yml:10-16` (environment block of `jellyfin-server`)
- Modify: `docker-compose.dev.yml:10-16` (environment block of `jellyfin-server`)
- Modify: `README.md:15` (architecture bullet) and add a discovery subsection after the "Architecture Deep Dive" section

**Interfaces:**
- Consumes: env var contract from Task 1 (`WORKER_TASKS_DNS`, `DISCOVERY_INTERVAL`, `REMOVE_AFTER_MISSES`, defaults `tasks.transcode-worker` / `30` / `2`).
- Produces: user-facing documentation; no code.

- [ ] **Step 1: Document the env vars in both compose files**

In `docker-compose.yml`, inside the `jellyfin-server` service `environment:` list (after the `NFS_EXPORT_1` line), add:

```yaml
      # Worker discovery (defaults shown; uncomment only to override).
      # WORKER_TASKS_DNS must match "tasks.<worker service name>" if you
      # rename the transcode-worker service.
      # - WORKER_TASKS_DNS=tasks.transcode-worker
      # - DISCOVERY_INTERVAL=30
      # - REMOVE_AFTER_MISSES=2
```

Apply the identical block in `docker-compose.dev.yml` at the same position.

- [ ] **Step 2: Update the README architecture bullet**

In `README.md`, the `jellyfin-server` bullet (line 15) currently ends with:

```
This service also runs an integrated **NFS server** to share the `/transcodes` and `/cache` directories, ensuring all nodes have access to the same temporary files. **Logs for `rffmpeg` are automatically viewable in the Jellyfin Dashboard under the "Logs" section.**
```

Extend it by inserting one sentence before the Logs sentence:

```
This service also runs an integrated **NFS server** to share the `/transcodes` and `/cache` directories, ensuring all nodes have access to the same temporary files. Workers are discovered automatically within seconds via Swarm DNS and an SSH health probe (see "Worker Discovery" below). **Logs for `rffmpeg` are automatically viewable in the Jellyfin Dashboard under the "Logs" section.**
```

- [ ] **Step 3: Add a Worker Discovery section**

In `README.md`, immediately after the "Architecture Deep Dive: The Embedded NFS Server" section (after the Troubleshooting bullet, before "## Credits"), add:

```markdown
## Worker Discovery

The `jellyfin-server` container runs a small discovery daemon that keeps the rffmpeg host list in sync with the actual state of the Swarm:

1. Every 30 seconds it resolves `tasks.transcode-worker` via Swarm DNS, which returns the IPs of all *running* worker tasks in a single lookup.
2. Each IP is probed over SSH (the same transport rffmpeg uses to dispatch jobs) and asked for its slot-stable hostname. A worker that is still starting up, or whose SSH daemon has died, fails the probe and is not registered.
3. Healthy workers are added with `rffmpeg add`; workers that fail the probe on 2 consecutive passes are removed.

This means new workers accept jobs within seconds of `docker service scale`, and a restarted `jellyfin-server` re-registers all workers almost immediately. Hosts you add manually with `rffmpeg add` are never touched by the daemon.

You can tune the behavior with environment variables on the `jellyfin-server` service: `WORKER_TASKS_DNS` (default `tasks.transcode-worker`; change it if you rename the worker service), `DISCOVERY_INTERVAL` (seconds between passes, default `30`), and `REMOVE_AFTER_MISSES` (consecutive failed passes before removal, default `2`).
```

- [ ] **Step 4: Verify**

Run: `bash tests/test-discovery.sh` one more time (regression) — expect `ALL TESTS PASSED`.
Run: `docker compose -f docker-compose.yml config >/dev/null` if Docker is available — expect no YAML errors (warnings about unset `YOUR_NFS_SERVER_IP` placeholders are pre-existing and fine). If Docker is unavailable, any YAML parser check is acceptable.

- [ ] **Step 5: Commit**

```bash
git add docker-compose.yml docker-compose.dev.yml README.md
git commit -m "docs: document DNS+SSH worker discovery and its env vars"
```

---

## Deployment Verification (manual, on the swarm — Chris runs this)

Not part of the automated tasks; listed for the rollout after images are built:

1. Deploy the updated stack, then `docker service logs jellyfin_jellyfin-server | grep discovery` — expect "starting worker discovery" at boot and "added jellyfin-transcode-N" lines within ~35 seconds.
2. `docker exec` into the server container: `rffmpeg status` should list all running workers.
3. Scale test: `docker service scale jellyfin_transcode-worker=3` — new worker should appear in `rffmpeg status` within one interval; scale back down — removed after ~2 intervals.
4. Restart test: `docker service update --force jellyfin_jellyfin-server` — workers re-registered within ~35 seconds of the new task starting (previously up to 15 minutes).
5. Sanity check on Swarm DNS: inside the server container, `getent hosts tasks.transcode-worker` must return one line per running worker. If it returns nothing, set `WORKER_TASKS_DNS=tasks.<stack>_transcode-worker` in the compose environment block.
