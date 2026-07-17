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
    if [ -f "$STUB_STATE/fail_remove" ]; then exit 1; fi
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

# --- test 7: failed remove is retried, host never orphaned ------------
(
  setup_case t7
  echo "10.0.0.2 tasks.transcode-worker" > "$STUB_STATE/dns.txt"
  echo "10.0.0.2 jellyfin-transcode-1" > "$STUB_STATE/ssh_map.txt"
  run_pass
  # worker vanishes and rffmpeg remove starts failing
  : > "$STUB_STATE/dns.txt"
  touch "$STUB_STATE/fail_remove"
  run_pass
  run_pass
  assert "host still registered while remove fails" registered jellyfin-transcode-1
  assert "host still tracked in state file while remove fails" grep -qw jellyfin-transcode-1 "$STATE_FILE"
  # remove works again: next pass must clean up
  rm -f "$STUB_STATE/fail_remove"
  run_pass
  assert "host removed once remove succeeds" not_registered jellyfin-transcode-1
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
