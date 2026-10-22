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
HELPER="$REPO/jellyfin-rffmpeg-server/recording-metadata.py"
export METADATA_HELPER="$HELPER"
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
log_has() { grep -qF -- "$1" "$LOG_DIR"/post-processing_*.log; }

# --- stubs ---
mkdir -p "$WORK/bin"
cat > "$WORK/bin/comskip" <<'EOF'
#!/bin/bash
in="${@: -1}"
printf '0.00\t60.00\t0\n' > "${in%.*}.edl"
echo "comskip stub" > "${in%.*}.log"
EOF
cat > "$WORK/bin/comchap" <<'EOF'
#!/bin/bash
args=("$@"); n=${#args[@]}
cp "${args[$((n-2))]}" "${args[$((n-1))]}"
rm -f "${args[$((n-2))]%.*}".{edl,log}
EOF
chmod +x "$WORK/bin/comskip" "$WORK/bin/comchap"
export COMSKIP_BIN="$WORK/bin/comskip" COMCHAP_BIN="$WORK/bin/comchap" COMSKIP_INI=/dev/null

# --- fake Jellyfin image endpoint: [/jf]/Items/<id>/Images/<type> -> "<id>:<type>" ---
#   prog-full:    all four types, Logo as PNG
#   prog-partial: Primary ok, Backdrop fails with 500
#   prog-*:       Primary and Backdrop
cat > "$WORK/server.py" <<'EOF'
import http.server, sys
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        parts = self.path.strip("/").split("/")
        if parts and parts[0] == "jf":
            parts = parts[1:]
        if not (len(parts) == 4 and parts[0] == "Items" and parts[2] == "Images" and parts[1].startswith("prog-")):
            self.send_response(404); self.end_headers(); return
        item, kind = parts[1], parts[3]
        types = ("Primary", "Thumb", "Backdrop", "Logo") if item == "prog-full" else ("Primary", "Backdrop")
        if item == "prog-partial" and kind == "Backdrop":
            self.send_response(500); self.end_headers(); return
        if kind not in types:
            self.send_response(404); self.end_headers(); return
        body = f"{item}:{kind}".encode()
        self.send_response(200)
        self.send_header("Content-Type", "image/png" if kind == "Logo" else "image/jpeg")
        self.end_headers(); self.wfile.write(body)
    def log_message(self, *a): pass
s = http.server.HTTPServer(("127.0.0.1", 0), H)
open(sys.argv[1], "w").write(str(s.server_port))
s.serve_forever()
EOF
"$PYTHON_BIN" "$WORK/server.py" "$WORK/port" & SERVER_PID=$!
for _ in $(seq 50); do [ -s "$WORK/port" ] && break; sleep 0.1; done
PORT="$(cat "$WORK/port")"
export RECMETA_JELLYFIN_URL="http://127.0.0.1:$PORT"

# --- per-test setup ---
# new_case: fresh livetv root, log dir, timers file and database.
new_case() {
    CASE="$WORK/case$((++CASE_N))"
    mkdir -p "$CASE/livetv" "$CASE/log" "$CASE/temp"
    export LIVETV_ROOT="$CASE/livetv" LOG_DIR="$CASE/log" TEMP_DIR="$CASE/temp"
    export RECMETA_TIMERS_FILE="$CASE/timers.json" RECMETA_JELLYFIN_DB="$CASE/jellyfin.db"
    echo '[]' > "$RECMETA_TIMERS_FILE"
    "$PYTHON_BIN" -c "import sqlite3,sys; c=sqlite3.connect(sys.argv[1]); c.execute('CREATE TABLE BaseItems (Id TEXT, Type TEXT, ExternalId TEXT)'); c.commit()" "$RECMETA_JELLYFIN_DB"
}
CASE_N=0

# completed_timer <channel> <recording path> [program id]: what Jellyfin saves
# before running the post-processor.
completed_timer() {
    "$PYTHON_BIN" - "$RECMETA_TIMERS_FILE" "$@" <<'EOF'
import json, sys
f, ch, path = sys.argv[1:4]
pid = sys.argv[4] if len(sys.argv) > 4 else f"{ch}_none"
t = json.load(open(f))
t.append({"Id": f"t{len(t)}", "Status": "Completed", "ChannelId": ch, "ProgramId": pid, "RecordingPath": path})
json.dump(t, open(f, "w"))
EOF
}
# add_program <external id> <item id>
add_program() {
    "$PYTHON_BIN" -c "import sqlite3,sys; c=sqlite3.connect(sys.argv[1]); c.execute('INSERT INTO BaseItems VALUES (?, ?, ?)', (sys.argv[3], 'MediaBrowser.Controller.LiveTv.LiveTvProgram', sys.argv[2])); c.commit()" "$RECMETA_JELLYFIN_DB" "$1" "$2"
}
# record <path>: a recording plus the .nfo Jellyfin writes beside it.
record() { mkdir -p "$(dirname "$1")"; echo video > "$1"; echo nfo > "${1%.*}.nfo"; }
run() { bash "$SCRIPT" "$1"; }

SHOW="Live  Football"
A_NAME="$SHOW 2026_10_21_11_30_00"
B_NAME="$SHOW 2026_10_21_13_50_00"

# 1. Overlapping same-title games, each with guide art. Each gets its own
#    program's art; the shared folder's copy is never used; the shared folder
#    is cleaned up only when the last recording leaves.
new_case
SHARED="$LIVETV_ROOT/$SHOW"
record "$SHARED/$A_NAME.ts"; record "$SHARED/$B_NAME.ts"
echo "B art" > "$SHARED/poster.jpg"   # B started last and overwrote A's poster
completed_timer hdhr_217 "$SHARED/$A_NAME.ts" pa; add_program pa prog-a
run "$SHARED/$A_NAME.ts"
A_DIR="$LIVETV_ROOT/$A_NAME [hdhr_217]"
check "1: A in channel-tagged folder" [ -f "$A_DIR/$A_NAME.mkv" ]
check "1: A nfo moved" [ -f "$A_DIR/$A_NAME.nfo" ]
check "1: A poster is A's program art" has_content "$A_DIR/poster.jpg" "prog-a:Primary"
check "1: A fanart is A's program art" has_content "$A_DIR/fanart.jpg" "prog-a:Backdrop"
check "1: no landscape when guide has none" [ ! -e "$A_DIR/landscape.jpg" ]
check "1: shared art kept while B is still there" has_content "$SHARED/poster.jpg" "B art"
check "1: B's recording untouched" [ -f "$SHARED/$B_NAME.ts" ]
completed_timer hdhr_215 "$SHARED/$B_NAME.ts" pb; add_program pb prog-b
run "$SHARED/$B_NAME.ts"
B_DIR="$LIVETV_ROOT/$B_NAME [hdhr_215]"
check "1: B poster is B's program art" has_content "$B_DIR/poster.jpg" "prog-b:Primary"
check "1: shared folder removed after the last recording" [ ! -e "$SHARED" ]

# 2. No guide art: no artwork is taken from the shared folder, ever.
new_case
SHARED="$LIVETV_ROOT/$SHOW"
record "$SHARED/$A_NAME.ts"
echo "someone's art" > "$SHARED/poster.jpg"
completed_timer hdhr_217 "$SHARED/$A_NAME.ts"
run "$SHARED/$A_NAME.ts"
check "2: no art taken" [ ! -e "$LIVETV_ROOT/$A_NAME [hdhr_217]/poster.jpg" ]
check "2: stale shared art and folder cleaned up" [ ! -e "$SHARED" ]
check "2: log says why" log_has "Guide program artwork unavailable"

# 3. All four image types, mapped to Jellyfin's names, with the right extensions.
new_case
SHARED="$LIVETV_ROOT/$SHOW"
record "$SHARED/$A_NAME.ts"
completed_timer hdhr_1 "$SHARED/$A_NAME.ts" pf; add_program pf prog-full
run "$SHARED/$A_NAME.ts"
D="$LIVETV_ROOT/$A_NAME [hdhr_1]"
check "3: poster" has_content "$D/poster.jpg" "prog-full:Primary"
check "3: landscape" has_content "$D/landscape.jpg" "prog-full:Thumb"
check "3: fanart" has_content "$D/fanart.jpg" "prog-full:Backdrop"
check "3: logo as png" has_content "$D/logo.png" "prog-full:Logo"

# 4. Partial fetch: the types that worked are kept, the failure is logged.
new_case
SHARED="$LIVETV_ROOT/$SHOW"
record "$SHARED/$A_NAME.ts"
completed_timer hdhr_1 "$SHARED/$A_NAME.ts" pp; add_program pp prog-partial
run "$SHARED/$A_NAME.ts"
D="$LIVETV_ROOT/$A_NAME [hdhr_1]"
check "4: poster kept" has_content "$D/poster.jpg" "prog-partial:Primary"
check "4: no fanart" [ ! -e "$D/fanart.jpg" ]
check "4: failure logged" log_has "Backdrop: HTTP 500"

# 5. Same title, same start, two channels: two folders, art kept apart.
new_case
SHARED="$LIVETV_ROOT/$SHOW"
record "$SHARED/$A_NAME.ts"; record "$SHARED/$A_NAME - 1.ts"
completed_timer hdhr_10 "$SHARED/$A_NAME.ts" px; add_program px prog-x
completed_timer hdhr_20 "$SHARED/$A_NAME - 1.ts" py; add_program py prog-y
run "$SHARED/$A_NAME.ts"
run "$SHARED/$A_NAME - 1.ts"
check "5: first in its own folder" [ -f "$LIVETV_ROOT/$A_NAME [hdhr_10]/$A_NAME.mkv" ]
check "5: second in its own folder" [ -f "$LIVETV_ROOT/$A_NAME - 1 [hdhr_20]/$A_NAME - 1.mkv" ]
NFOS=("$LIVETV_ROOT/$A_NAME [hdhr_10]"/*.nfo)
check "5: first has only its own nfo" [ "${#NFOS[@]}" = 1 ]
check "5: first art is its own" has_content "$LIVETV_ROOT/$A_NAME [hdhr_10]/poster.jpg" "prog-x:Primary"
check "5: second art is its own" has_content "$LIVETV_ROOT/$A_NAME - 1 [hdhr_20]/poster.jpg" "prog-y:Primary"

# 6. A recording directly in the recording root: its art arrives, nothing else
#    in the root is touched.
new_case
record "$LIVETV_ROOT/$A_NAME.ts"
echo bystander > "$LIVETV_ROOT/poster.jpg"
completed_timer hdhr_3 "$LIVETV_ROOT/$A_NAME.ts" pr; add_program pr prog-r
run "$LIVETV_ROOT/$A_NAME.ts"
check "6: moved into its own folder" [ -f "$LIVETV_ROOT/$A_NAME [hdhr_3]/$A_NAME.mkv" ]
check "6: art arrives" has_content "$LIVETV_ROOT/$A_NAME [hdhr_3]/poster.jpg" "prog-r:Primary"
check "6: root bystander untouched" has_content "$LIVETV_ROOT/poster.jpg" "bystander"

# 7. Destination already holds another recording: never merge into it.
new_case
SHARED="$LIVETV_ROOT/$SHOW"
mkdir -p "$LIVETV_ROOT/$A_NAME [hdhr_217]"; echo other > "$LIVETV_ROOT/$A_NAME [hdhr_217]/other.mkv"
record "$SHARED/$A_NAME.ts"
completed_timer hdhr_217 "$SHARED/$A_NAME.ts"
run "$SHARED/$A_NAME.ts"
SUFFIXED="$LIVETV_ROOT/$A_NAME [hdhr_217] (2)"
check "7: suffixed folder" [ -f "$SUFFIXED/$A_NAME.mkv" ]
check "7: existing folder untouched" [ "$(ls "$LIVETV_ROOT/$A_NAME [hdhr_217]")" = "other.mkv" ]

# 8. Rerun of an already-moved recording: timers.json still points at the old
#    shared path, so no timer matches; the recording stays where it is.
for dir in "$A_NAME [hdhr_217]" "$A_NAME [hdhr_217] (2)" "$A_NAME" "$A_NAME (3)"; do
    new_case
    record "$LIVETV_ROOT/$dir/$A_NAME.mkv"
    completed_timer hdhr_217 "$LIVETV_ROOT/$SHOW/$A_NAME.ts"
    run "$LIVETV_ROOT/$dir/$A_NAME.mkv"
    check "8: rerun stays in '$dir'" [ -f "$LIVETV_ROOT/$dir/$A_NAME.mkv" ]
done
# ...also when the title contains regex characters.
new_case
ODD="Live  U.S. Open (Cup) + [Final] 2026_10_21_19_00_00"
record "$LIVETV_ROOT/$ODD [hdhr_9] (2)/$ODD.mkv"
run "$LIVETV_ROOT/$ODD [hdhr_9] (2)/$ODD.mkv"
check "8: rerun with regex characters stays" [ -f "$LIVETV_ROOT/$ODD [hdhr_9] (2)/$ODD.mkv" ]

# 9. No timer: folder named from the file, no art, and another recording's
#    shared folder and art are left alone.
new_case
SHARED="$LIVETV_ROOT/$SHOW"
record "$SHARED/$A_NAME.ts"; record "$SHARED/$B_NAME.ts"
echo "B art" > "$SHARED/poster.jpg"
run "$SHARED/$A_NAME.ts"
check "9: folder named from file" [ -f "$LIVETV_ROOT/$A_NAME/$A_NAME.mkv" ]
check "9: no art" [ ! -e "$LIVETV_ROOT/$A_NAME/poster.jpg" ]
check "9: sibling's shared art kept" has_content "$SHARED/poster.jpg" "B art"

# 10. Series recordings keep Jellyfin's layout and get no extra artwork.
new_case
SDIR="$LIVETV_ROOT/Some Show/Season 1"
record "$SDIR/Some Show S01E02.ts"
completed_timer hdhr_5 "$SDIR/Some Show S01E02.ts" ps; add_program ps prog-s
run "$SDIR/Some Show S01E02.ts"
check "10: series left in place" [ -f "$SDIR/Some Show S01E02.mkv" ]
check "10: no poster in the season folder" [ ! -e "$SDIR/poster.jpg" ]

# 11. A movie recorded again under the same name never replaces the earlier
#     recording's .mkv.
new_case
MDIR="$LIVETV_ROOT/Movie (2020)"
mkdir -p "$MDIR"; echo "first recording" > "$MDIR/Movie (2020).mkv"; echo nfo > "$MDIR/Movie (2020).nfo"
echo "second recording" > "$MDIR/Movie (2020).ts"
run "$MDIR/Movie (2020).ts"
check "11: first recording intact" has_content "$MDIR/Movie (2020).mkv" "first recording"
check "11: second saved beside it" has_content "$MDIR/Movie (2020) - 1.mkv" "second recording"

# 12. Unsafe characters in a channel id never leave the recording root.
new_case
SHARED="$LIVETV_ROOT/$SHOW"
record "$SHARED/$A_NAME.ts"
completed_timer "a/../b c" "$SHARED/$A_NAME.ts"
run "$SHARED/$A_NAME.ts"
check "12: channel id sanitised" [ -f "$LIVETV_ROOT/$A_NAME [a_.._b_c]/$A_NAME.mkv" ]

# 13. A control character in a timer field is dropped, not passed on.
new_case
"$PYTHON_BIN" - "$RECMETA_TIMERS_FILE" <<'EOF'
import json, sys
json.dump([{"Status": "Completed", "RecordingPath": "rec/x.ts", "ChannelId": "hdhr_1", "ProgramId": "p\nCHANNEL_ID=evil"}], open(sys.argv[1], "w"))
EOF
OUT="$("$PYTHON_BIN" "$HELPER" timer rec/x.ts)"
OUT="${OUT//$'\r'/}"
check "13: channel kept" grep -qx "CHANNEL_ID=hdhr_1" <<<"$OUT"
check "13: bad program id blanked" grep -qx "PROGRAM_ID=" <<<"$OUT"
check "13: nothing injected" [ "$(grep -c CHANNEL_ID <<<"$OUT")" = 1 ]

# 14. timers.json with a BOM is read; an unreadable one means "no timer".
new_case
printf '\xef\xbb\xbf[{"Status":"Completed","RecordingPath":"rec/y.ts","ChannelId":"c1","ProgramId":"p1"}]' > "$RECMETA_TIMERS_FILE"
check "14: BOM file read" grep -q "PROGRAM_ID=p1" <<<"$("$PYTHON_BIN" "$HELPER" timer rec/y.ts)"
echo '[{"broken' > "$RECMETA_TIMERS_FILE"
"$PYTHON_BIN" "$HELPER" timer rec/y.ts >/dev/null 2>&1
RC=$?
check "14: unreadable file exits 1" [ "$RC" = 1 ]

# 15. Without an explicit URL the image endpoint comes from network.xml
#     (port and BaseUrl).
new_case
SHARED="$LIVETV_ROOT/$SHOW"
record "$SHARED/$A_NAME.ts"
completed_timer hdhr_1 "$SHARED/$A_NAME.ts" pn; add_program pn prog-n
printf '<NetworkConfiguration><BaseUrl>/jf</BaseUrl><InternalHttpPort>%s</InternalHttpPort></NetworkConfiguration>' "$PORT" > "$CASE/network.xml"
RECMETA_JELLYFIN_URL="" RECMETA_NETWORK_CONFIG="$CASE/network.xml" run "$SHARED/$A_NAME.ts"
check "15: art fetched via network.xml" has_content "$LIVETV_ROOT/$A_NAME [hdhr_1]/poster.jpg" "prog-n:Primary"

# 16. A folder name too long for the filesystem: the recording stays put and
#     the failure is logged.
new_case
LONG="$(printf 'x%.0s' $(seq 230))"
SHARED="$LIVETV_ROOT/$SHOW"
record "$SHARED/$LONG.ts"
completed_timer hdhr_123456789012345678901234567 "$SHARED/$LONG.ts"
run "$SHARED/$LONG.ts" 2>/dev/null
check "16: recording left in place" [ -f "$SHARED/$LONG.mkv" ]
check "16: error logged" log_has "ERROR: could not move the recording"

# 17. A same-name video already in the shared folder is another recording: the
#     processed file is renamed around it and it is not moved along.
new_case
SHARED="$LIVETV_ROOT/$SHOW"
mkdir -p "$SHARED"; echo "other recording" > "$SHARED/$A_NAME.mkv"
record "$SHARED/$A_NAME.ts"
completed_timer hdhr_7 "$SHARED/$A_NAME.ts"
run "$SHARED/$A_NAME.ts"
check "17: other recording left in place" has_content "$SHARED/$A_NAME.mkv" "other recording"
check "17: this recording moved under a new name" [ -f "$LIVETV_ROOT/$A_NAME [hdhr_7]/$A_NAME - 1.mkv" ]

# 18. Any file besides the artwork keeps the shared folder in use.
new_case
SHARED="$LIVETV_ROOT/$SHOW"
mkdir -p "$SHARED"; echo art > "$SHARED/poster.jpg"; echo video > "$SHARED/clip.mp4"
"$PYTHON_BIN" "$HELPER" clean-shared "$SHARED"
check "18: art kept while another file is there" has_content "$SHARED/poster.jpg" "art"
rm "$SHARED/clip.mp4"
"$PYTHON_BIN" "$HELPER" clean-shared "$SHARED" >/dev/null
check "18: folder removed once only art is left" [ ! -e "$SHARED" ]

echo "passed: $PASS  failed: $FAIL"
[ "$FAIL" -eq 0 ]
