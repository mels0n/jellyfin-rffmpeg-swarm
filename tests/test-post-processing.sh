#!/bin/bash
# Tests for the DVR post-processor's per-recording folders and artwork.
#
# comskip and comchap are stubbed, Jellyfin's timers.json and database are
# fixtures, and a small local HTTP server stands in for Jellyfin's image
# endpoint. Needs bash, python3 (with sqlite3) and coreutils.
#
# Usage: tests/test-post-processing.sh   (KEEP=1 keeps the work directory)

set -u

REPO="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$REPO/jellyfin-rffmpeg-server/recording-post-proceessing.sh"
export METADATA_HELPER="$REPO/jellyfin-rffmpeg-server/recording-metadata.py"
export PYTHON_BIN="${PYTHON_BIN:-python3}"

WORK="$(mktemp -d)"
# Python on Windows needs drive-letter paths; elsewhere this is a no-op.
command -v cygpath >/dev/null 2>&1 && WORK="$(cygpath -m "$WORK")"
trap 'kill "$SERVER_PID" 2>/dev/null; [ -n "${KEEP:-}" ] || rm -rf "$WORK"' EXIT

PASS=0
FAIL=0
check() { # check <description> <command...>
    local desc="$1"; shift
    if "$@"; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); echo "FAIL: $desc"; fi
}
has_content() { [ -f "$1" ] && [ "$(cat "$1")" = "$2" ]; }

# --- stubs ---
# comskip runs $CASE/during-comskip, if present, to simulate events while it works.
mkdir -p "$WORK/bin"
cat > "$WORK/bin/comskip" <<'EOF'
#!/bin/bash
in="${@: -1}"
printf '0.00\t60.00\t0\n' > "${in%.*}.edl"
echo "comskip stub" > "${in%.*}.log"
[ -x "$CASE/during-comskip" ] && "$CASE/during-comskip"
exit 0
EOF
cat > "$WORK/bin/comchap" <<'EOF'
#!/bin/bash
args=("$@"); n=${#args[@]}
cp "${args[$((n-2))]}" "${args[$((n-1))]}"
rm -f "${args[$((n-2))]%.*}".{edl,log}
EOF
chmod +x "$WORK/bin/comskip" "$WORK/bin/comchap"
export COMSKIP_BIN="$WORK/bin/comskip" COMCHAP_BIN="$WORK/bin/comchap" COMSKIP_INI=/dev/null

# --- fake Jellyfin image endpoint: /Items/<id>/Images/<type> -> "<id>:<type>" ---
cat > "$WORK/server.py" <<'EOF'
import http.server, sys
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        parts = self.path.strip("/").split("/")
        if len(parts) == 4 and parts[0] == "Items" and parts[2] == "Images" and parts[1].startswith("prog-") and parts[3] in ("Primary", "Backdrop"):
            body = f"{parts[1]}:{parts[3]}".encode()
            self.send_response(200); self.send_header("Content-Type", "image/jpeg"); self.end_headers(); self.wfile.write(body)
        else:
            self.send_response(404); self.end_headers()
    def log_message(self, *a): pass
s = http.server.HTTPServer(("127.0.0.1", 0), H)
open(sys.argv[1], "w").write(str(s.server_port))
s.serve_forever()
EOF
"$PYTHON_BIN" "$WORK/server.py" "$WORK/port" & SERVER_PID=$!
for _ in $(seq 50); do [ -s "$WORK/port" ] && break; sleep 0.1; done
JELLYFIN_URL="http://127.0.0.1:$(cat "$WORK/port")"
export JELLYFIN_URL

# --- per-test setup ---
# new_case: fresh livetv root, log dir, timers file and database.
new_case() {
    CASE="$WORK/case$((++CASE_N))"
    mkdir -p "$CASE/livetv" "$CASE/log" "$CASE/temp"
    export CASE LIVETV_ROOT="$CASE/livetv" LOG_DIR="$CASE/log" TEMP_DIR="$CASE/temp"
    export TIMERS_FILE="$CASE/timers.json" JELLYFIN_DB="$CASE/jellyfin.db"
    echo '[]' > "$TIMERS_FILE"
    "$PYTHON_BIN" -c "import sqlite3,sys; c=sqlite3.connect(sys.argv[1]); c.execute('CREATE TABLE BaseItems (Id TEXT, Type TEXT, ExternalId TEXT)'); c.commit()" "$JELLYFIN_DB"
}
CASE_N=0

# start_timer <id> <name> <channel> <start> [program id]
#   A recording in progress, as Jellyfin stores it: Status InProgress and no
#   RecordingPath yet (that is only set when the recording completes).
start_timer() {
    "$PYTHON_BIN" - "$TIMERS_FILE" "$@" <<'EOF'
import json, sys
f, tid, name, ch, start = sys.argv[1:6]
pid = sys.argv[6] if len(sys.argv) > 6 else f"{ch}_{start}"
t = json.load(open(f))
t.append({"Id": tid, "Name": name, "Status": "InProgress", "ChannelId": ch, "ProgramId": pid,
          "StartDate": start, "PrePaddingSeconds": 0})
json.dump(t, open(f, "w"))
EOF
}
# complete_timer <id> <recording path>: what Jellyfin saves before running the
# post-processor. Completed timers are kept afterwards.
complete_timer() {
    "$PYTHON_BIN" - "$TIMERS_FILE" "$@" <<'EOF'
import json, sys
f, tid, path = sys.argv[1:4]
t = json.load(open(f))
for x in t:
    if x["Id"] == tid:
        x["Status"] = "Completed"; x["RecordingPath"] = path
json.dump(t, open(f, "w"))
EOF
}
# add_program <external id> <item id>
add_program() {
    "$PYTHON_BIN" -c "import sqlite3,sys; c=sqlite3.connect(sys.argv[1]); c.execute('INSERT INTO BaseItems VALUES (?, ?, ?)', (sys.argv[3], 'MediaBrowser.Controller.LiveTv.LiveTvProgram', sys.argv[2])); c.commit()" "$JELLYFIN_DB" "$1" "$2"
}
# record <path>: a recording plus the .nfo Jellyfin writes beside it.
record() { mkdir -p "$(dirname "$1")"; echo video > "$1"; echo nfo > "${1%.*}.nfo"; }
run() { bash "$SCRIPT" "$1"; }
# finish <timer id> <path>: Jellyfin completes the timer, then runs the post-processor.
finish() { complete_timer "$1" "$2"; run "$2"; }
dir_of() { dirname "$(find "$LIVETV_ROOT" -name "$1.mkv" | head -1)"; }

TITLE="Live: Football"
SHOW="Live  Football"
A_START="2026-10-21T16:30:00.0000000Z"; A_NAME="$SHOW 2026_10_21_11_30_00"
B_START="2026-10-21T18:50:00.0000000Z"; B_NAME="$SHOW 2026_10_21_13_50_00"
C_START="2026-10-21T20:00:00.0000000Z"

# 1. Overlapping same-title games, guide has both programs. The earlier one
#    finishes first; each gets its own program's art; shared art is cleaned up.
new_case
SHARED="$LIVETV_ROOT/$SHOW"
record "$SHARED/$A_NAME.ts"; record "$SHARED/$B_NAME.ts"
echo "B art" > "$SHARED/poster.jpg"   # B started last and overwrote A's poster
start_timer a "$TITLE" hdhr_217 "$A_START" pa; add_program pa prog-a
start_timer b "$TITLE" hdhr_215 "$B_START" pb; add_program pb prog-b
finish a "$SHARED/$A_NAME.ts"
A_DIR="$LIVETV_ROOT/$A_NAME [hdhr_217]"
check "1: A in channel-tagged folder" [ -f "$A_DIR/$A_NAME.mkv" ]
check "1: A nfo moved" [ -f "$A_DIR/$A_NAME.nfo" ]
check "1: A poster is A's program art" has_content "$A_DIR/poster.jpg" "prog-a:Primary"
check "1: A fanart is A's program art" has_content "$A_DIR/fanart.jpg" "prog-a:Backdrop"
check "1: no landscape when guide has none" [ ! -e "$A_DIR/landscape.jpg" ]
check "1: B's shared poster left alone" has_content "$SHARED/poster.jpg" "B art"
check "1: B's recording untouched" [ -f "$SHARED/$B_NAME.ts" ]
finish b "$SHARED/$B_NAME.ts"
B_DIR="$LIVETV_ROOT/$B_NAME [hdhr_215]"
check "1: B poster is B's program art" has_content "$B_DIR/poster.jpg" "prog-b:Primary"
check "1: shared folder removed" [ ! -e "$SHARED" ]

# 2. Same, but the guide no longer has the programs. The earlier game must not
#    take the later game's art; the later one takes it.
new_case
SHARED="$LIVETV_ROOT/$SHOW"
record "$SHARED/$A_NAME.ts"; record "$SHARED/$B_NAME.ts"
echo "B art" > "$SHARED/poster.jpg"
start_timer a "$TITLE" hdhr_217 "$A_START"
start_timer b "$TITLE" hdhr_215 "$B_START"
finish a "$SHARED/$A_NAME.ts"
check "2: A gets no art" [ ! -e "$(dir_of "$A_NAME")/poster.jpg" ]
check "2: shared poster kept for B" has_content "$SHARED/poster.jpg" "B art"
finish b "$SHARED/$B_NAME.ts"
check "2: B takes its art from the shared folder" has_content "$(dir_of "$B_NAME")/poster.jpg" "B art"
check "2: shared folder removed" [ ! -e "$SHARED" ]

# 3. Later-started game finishes first, guide missing: it takes its own art,
#    and the earlier game must not inherit anything afterwards (the old bug).
new_case
SHARED="$LIVETV_ROOT/$SHOW"
record "$SHARED/$A_NAME.ts"; record "$SHARED/$B_NAME.ts"
echo "B art" > "$SHARED/poster.jpg"
start_timer a "$TITLE" hdhr_217 "$A_START"
start_timer b "$TITLE" hdhr_215 "$B_START"
finish b "$SHARED/$B_NAME.ts"
check "3: B takes its art" has_content "$(dir_of "$B_NAME")/poster.jpg" "B art"
echo "stale" > "$SHARED/poster.jpg"   # even if something is left behind
finish a "$SHARED/$A_NAME.ts"
check "3: A does not take art from a later recording" [ ! -e "$(dir_of "$A_NAME")/poster.jpg" ]

# 4. Same title, same start, two channels: two folders, art kept apart.
new_case
SHARED="$LIVETV_ROOT/$SHOW"
record "$SHARED/$A_NAME.ts"; record "$SHARED/$A_NAME - 1.ts"
start_timer x "$TITLE" hdhr_10 "$A_START" px; add_program px prog-x
start_timer y "$TITLE" hdhr_20 "$A_START" py; add_program py prog-y
finish x "$SHARED/$A_NAME.ts"
finish y "$SHARED/$A_NAME - 1.ts"
check "4: first in its own folder" [ -f "$LIVETV_ROOT/$A_NAME [hdhr_10]/$A_NAME.mkv" ]
check "4: second in its own folder" [ -f "$LIVETV_ROOT/$A_NAME - 1 [hdhr_20]/$A_NAME - 1.mkv" ]
NFOS=("$LIVETV_ROOT/$A_NAME [hdhr_10]"/*.nfo)
check "4: first has only its own nfo" [ "${#NFOS[@]}" = 1 ]
check "4: first art is its own" has_content "$LIVETV_ROOT/$A_NAME [hdhr_10]/poster.jpg" "prog-x:Primary"
check "4: second art is its own" has_content "$LIVETV_ROOT/$A_NAME - 1 [hdhr_20]/poster.jpg" "prog-y:Primary"

# 5. Same title, same start, guide missing: nobody can tell whose the shared
#    art is, so neither takes it.
new_case
SHARED="$LIVETV_ROOT/$SHOW"
record "$SHARED/$A_NAME.ts"; record "$SHARED/$A_NAME - 1.ts"
echo "someone's art" > "$SHARED/poster.jpg"
start_timer x "$TITLE" hdhr_10 "$A_START"
start_timer y "$TITLE" hdhr_20 "$A_START"
finish x "$SHARED/$A_NAME.ts"
finish y "$SHARED/$A_NAME - 1.ts"
check "5: first takes no art" [ ! -e "$LIVETV_ROOT/$A_NAME [hdhr_10]/poster.jpg" ]
check "5: second takes no art" [ ! -e "$LIVETV_ROOT/$A_NAME - 1 [hdhr_20]/poster.jpg" ]

# 6. A later same-title recording starts while comskip runs and overwrites the
#    shared art; ownership is re-read, so the finishing recording leaves it.
new_case
SHARED="$LIVETV_ROOT/$SHOW"
record "$SHARED/$A_NAME.ts"
echo "A art" > "$SHARED/poster.jpg"
start_timer a "$TITLE" hdhr_217 "$A_START"
cat > "$CASE/during-comskip" <<EOF
#!/bin/bash
echo "C art" > "$SHARED/poster.jpg"
echo video > "$SHARED/$SHOW 2026_10_21_15_00_00.ts"
TIMERS_FILE="$TIMERS_FILE" PYTHON_BIN="$PYTHON_BIN" bash -c '$(declare -f start_timer); start_timer c "$TITLE" hdhr_215 "$C_START"'
EOF
chmod +x "$CASE/during-comskip"
finish a "$SHARED/$A_NAME.ts"
check "6: A does not take C's art" [ ! -e "$(dir_of "$A_NAME")/poster.jpg" ]
check "6: C's art left in place" has_content "$SHARED/poster.jpg" "C art"

# 7. Pre-padding: the other recording's program starts later, but its padding
#    made it begin earlier, so this one started last and owns the shared art.
new_case
SHARED="$LIVETV_ROOT/$SHOW"
record "$SHARED/$A_NAME.ts"; record "$SHARED/$B_NAME.ts"
echo "A art" > "$SHARED/poster.jpg"
start_timer a "$TITLE" hdhr_217 "$A_START"
start_timer b "$TITLE" hdhr_215 "2026-10-21T16:31:00.0000000Z"
"$PYTHON_BIN" - "$TIMERS_FILE" <<'PY'
import json, sys
t = json.load(open(sys.argv[1]))
t[1]["PrePaddingSeconds"] = 120   # b began 16:29, a at 16:30
json.dump(t, open(sys.argv[1], "w"))
PY
finish a "$SHARED/$A_NAME.ts"
check "7: A owns the art despite B's later program start" has_content "$(dir_of "$A_NAME")/poster.jpg" "A art"

# 7b. A same-title recording that failed and waits to retry (New, RetryCount>0)
#     still counts: its art may be the one in the folder.
new_case
SHARED="$LIVETV_ROOT/$SHOW"
record "$SHARED/$A_NAME.ts"
echo "B art" > "$SHARED/poster.jpg"
start_timer a "$TITLE" hdhr_217 "$A_START"
start_timer b "Live/Football" hdhr_215 "$B_START"   # punctuation differs, same folder
"$PYTHON_BIN" - "$TIMERS_FILE" <<'PY'
import json, sys
t = json.load(open(sys.argv[1]))
t[1]["Status"] = "New"; t[1]["RetryCount"] = 1
json.dump(t, open(sys.argv[1], "w"))
PY
finish a "$SHARED/$A_NAME.ts"
check "7b: A leaves a retrying sibling's art" has_content "$SHARED/poster.jpg" "B art"

# 8. No timer (e.g. a manual rerun): file-name folder; shared art taken only
#    when no other recording is in the folder.
new_case
SHARED="$LIVETV_ROOT/$SHOW"
record "$SHARED/$A_NAME.ts"
echo "A art" > "$SHARED/poster.jpg"
run "$SHARED/$A_NAME.ts"
check "8: folder named from file" [ -f "$LIVETV_ROOT/$A_NAME/$A_NAME.mkv" ]
check "8: takes the shared art" has_content "$LIVETV_ROOT/$A_NAME/poster.jpg" "A art"

# 9. Destination already holds another recording: never merge into it; a rerun
#    inside the suffixed folder stays put.
new_case
SHARED="$LIVETV_ROOT/$SHOW"
mkdir -p "$LIVETV_ROOT/$A_NAME [hdhr_217]"; echo other > "$LIVETV_ROOT/$A_NAME [hdhr_217]/other.mkv"
record "$SHARED/$A_NAME.ts"
start_timer a "$TITLE" hdhr_217 "$A_START"
finish a "$SHARED/$A_NAME.ts"
SUFFIXED="$LIVETV_ROOT/$A_NAME [hdhr_217] (2)"
check "9: suffixed folder" [ -f "$SUFFIXED/$A_NAME.mkv" ]
check "9: existing folder untouched" [ "$(ls "$LIVETV_ROOT/$A_NAME [hdhr_217]")" = "other.mkv" ]
complete_timer a "$SUFFIXED/$A_NAME.mkv"
run "$SUFFIXED/$A_NAME.mkv"
check "9: rerun stays in the suffixed folder" [ -f "$SUFFIXED/$A_NAME.mkv" ]

# 10. Series recordings keep Jellyfin's layout.
new_case
SDIR="$LIVETV_ROOT/Some Show/Season 1"
record "$SDIR/Some Show S01E02.ts"
start_timer s "Some Show" hdhr_5 "$A_START"
finish s "$SDIR/Some Show S01E02.ts"
check "10: series left in place" [ -f "$SDIR/Some Show S01E02.mkv" ]

echo "passed: $PASS  failed: $FAIL"
[ "$FAIL" -eq 0 ]
