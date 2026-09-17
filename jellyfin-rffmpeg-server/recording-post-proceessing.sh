#!/bin/bash

# Jellyfin DVR post-processor.
#   1. Runs comskip on the recording and keeps its log in Jellyfin's log folder
#      (comskip_<date>_<recording>.log), where Jellyfin's log retention prunes it.
#   2. Runs comchap (chapters, default) or comcut (remove commercials) on the EDL.
#   3. Moves the finished recording into a folder of its own so each recording
#      shows as its own item with its own artwork. Series recordings are left alone.
#
# Invoked by Jellyfin as: /recording-post-processing.sh "{path}" [comchap|comcut] [extra comchap/comcut flags]

# Ensure all files created by this script and its children are group-writable.
umask 002

# Paths are overridable for testing; the defaults match the image layout.
LIVETV_ROOT="${LIVETV_ROOT:-/livetv}"
LOG_DIR="${LOG_DIR:-/config/log}"
TEMP_DIR="${TEMP_DIR:-/cache/temp}"
COMSKIP_BIN="${COMSKIP_BIN:-/usr/local/bin/comskip}"
COMCHAP_BIN="${COMCHAP_BIN:-/usr/local/bin/comchap}"
COMCUT_BIN="${COMCUT_BIN:-/usr/local/bin/comcut}"
COMSKIP_INI="${COMSKIP_INI:-/etc/comskip.ini}"

DATESTAMP=$(date +'%Y-%m-%d')
LOG_FILE="${LOG_DIR}/post-processing_${DATESTAMP}.log"
INPUT_FILE="$1"
shift # The first argument is always the file path.

# --- Argument Parsing ---
# Remaining arguments: the command and any optional flags, in any order.
COMMAND="comchap"
OPTIONAL_ARGS=""
for arg in "$@"; do
  case "$arg" in
    comcut|comchap)
      COMMAND="$arg"
      ;;
    *)
      OPTIONAL_ARGS="${OPTIONAL_ARGS} ${arg}"
      ;;
  esac
done

log() {
  echo "$*" >> "$LOG_FILE"
}

# --- Locking ---
LOCK_FILE="${TEMP_DIR}/$(basename "$INPUT_FILE").lock"

if [ -f "$LOCK_FILE" ]; then
    log "Lock file exists for $INPUT_FILE. Another process is running. Exiting."
    exit 1
fi

touch "$LOCK_FILE"
trap 'rm -f "$LOCK_FILE"' EXIT

log "----------------------------------------------------"
log "Processing request for: $INPUT_FILE"
date >> "$LOG_FILE"
log "Action: $COMMAND"
log "Using INI file: $COMSKIP_INI"

# Final output path. Chaptered output is always MKV.
OUTPUT_FILE="${INPUT_FILE%.*}.mkv"
INPUT_BASENAME="$(basename "${INPUT_FILE%.*}")"

# comchap/comcut mishandle spaces in filenames, so the recording is processed
# under a temporary space-free name in a known-good directory.
TEMP_BASENAME="post-processing-$(date +%s%N)-$$"
TEMP_INPUT_FILE="${LIVETV_ROOT}/${TEMP_BASENAME}.ts"
TEMP_OUTPUT_FILE="${LIVETV_ROOT}/${TEMP_BASENAME}.mkv"

mv "$INPUT_FILE" "$TEMP_INPUT_FILE"

# --- NFS workaround ---
# Wait for the moved file to become visible (NFS attribute caching).
i=0
while [ ! -f "$TEMP_INPUT_FILE" ] && [ $i -lt 10 ]; do
  sleep 1
  ((i++))
done

if [ ! -f "$TEMP_INPUT_FILE" ]; then
    log "ERROR: Moved temporary file is not visible after 10 seconds. Aborting."
    mv "$TEMP_INPUT_FILE" "$INPUT_FILE" 2>/dev/null
    exit 1
fi

# --- Commercial detection ---
# comskip writes <name>.edl/.log/.logo.txt/.txt next to its input. comchap and
# comcut reuse an existing EDL instead of running comskip again, which lets the
# log be captured here before they delete it.
COMSKIP_EDL="${TEMP_INPUT_FILE%.*}.edl"
COMSKIP_LOG="${TEMP_INPUT_FILE%.*}.log"
KEPT_LOG="${LOG_DIR}/comskip_${DATESTAMP}_${INPUT_BASENAME}.log"

log "Running comskip..."
"$COMSKIP_BIN" --ini="${COMSKIP_INI}" "${TEMP_INPUT_FILE}" > /dev/null 2>> "$LOG_FILE"
COMSKIP_EXIT=$?

if [ -f "$COMSKIP_LOG" ]; then
    cp "$COMSKIP_LOG" "$KEPT_LOG"
    {
      echo
      echo "################################################################"
      echo "EDL (start end type):"
      if [ -s "$COMSKIP_EDL" ]; then cat "$COMSKIP_EDL"; else echo "(no commercials found)"; fi
    } >> "$KEPT_LOG"
    log "comskip log saved to: $KEPT_LOG"
else
    log "WARNING: comskip produced no log file (exit code $COMSKIP_EXIT)."
fi

FINAL_FILE="$INPUT_FILE"

if [ ! -s "$COMSKIP_EDL" ]; then
    # Nothing to chapter or cut. Keep the original recording as is.
    log "No commercials found (comskip exit code $COMSKIP_EXIT). Original file is unchanged."
    rm -f "${TEMP_INPUT_FILE%.*}".{edl,log,logo.txt,txt}
    mv "$TEMP_INPUT_FILE" "$INPUT_FILE"
    EXIT_CODE=0
else
    case "$COMMAND" in
        comcut)
            log "Running comcut to physically remove commercials..."
            "$COMCUT_BIN" --comskip-ini="${COMSKIP_INI}" ${OPTIONAL_ARGS} "${TEMP_INPUT_FILE}" "${TEMP_OUTPUT_FILE}" >> "$LOG_FILE" 2>&1
            EXIT_CODE=$?
            ;;
        comchap)
            log "Running comchap to add chapter markers..."
            "$COMCHAP_BIN" --comskip-ini="${COMSKIP_INI}" ${OPTIONAL_ARGS} "${TEMP_INPUT_FILE}" "${TEMP_OUTPUT_FILE}" >> "$LOG_FILE" 2>&1
            EXIT_CODE=$?
            ;;
    esac

    if [ $EXIT_CODE -eq 0 ] && [ -s "$TEMP_OUTPUT_FILE" ]; then
        log "$COMMAND successful. Moving processed file to final destination."
        mv "$TEMP_OUTPUT_FILE" "$OUTPUT_FILE"
        rm -f "$TEMP_INPUT_FILE"
        FINAL_FILE="$OUTPUT_FILE"
    else
        log "ERROR: $COMMAND failed or created an empty file. Original file is unchanged."
        rm -f "$TEMP_OUTPUT_FILE"
        mv "$TEMP_INPUT_FILE" "$INPUT_FILE"
    fi
    # comchap/comcut normally remove these; make sure nothing is left behind.
    rm -f "${TEMP_INPUT_FILE%.*}".{edl,log,logo.txt,txt,ffmeta}
fi

if [ $EXIT_CODE -eq 0 ]; then
    log "Processing completed successfully."
else
    log "ERROR: Command '$COMMAND' failed. Check log for details."
fi

# --- Per-recording folder ---
# Jellyfin records every non-series program of the same name into one shared
# folder (<root>/<program name>/), so they show as one item with one poster.
# Move the finished recording, its .nfo, and the artwork Jellyfin copied in at
# recording start into a folder of its own. Series recordings (Season folders)
# keep Jellyfin's layout.
PARENT_DIR="$(dirname "$FINAL_FILE")"
PARENT_NAME="$(basename "$PARENT_DIR")"

if [ ! -f "$FINAL_FILE" ]; then
    log "Final file not found; skipping folder move: $FINAL_FILE"
elif [ "$PARENT_NAME" = "$INPUT_BASENAME" ]; then
    log "Recording already in its own folder."
elif [[ "$PARENT_NAME" =~ ^[Ss]eason ]] || [ -f "$PARENT_DIR/tvshow.nfo" ] || [ -f "$(dirname "$PARENT_DIR")/tvshow.nfo" ]; then
    log "Series recording; leaving folder layout to Jellyfin."
else
    if [ "$PARENT_DIR" = "$LIVETV_ROOT" ]; then
        DEST_DIR="${LIVETV_ROOT}/${INPUT_BASENAME}"
        SHARED_FOLDER=""
    else
        DEST_DIR="$(dirname "$PARENT_DIR")/${INPUT_BASENAME}"
        SHARED_FOLDER="$PARENT_DIR"
    fi

    mkdir -p "$DEST_DIR"
    mv "$FINAL_FILE" "$DEST_DIR/"
    # Sidecars written by Jellyfin for this recording (.nfo, -thumb.jpg, ...).
    for f in "$PARENT_DIR/$INPUT_BASENAME".* "$PARENT_DIR/$INPUT_BASENAME"-*; do
        [ -e "$f" ] && mv "$f" "$DEST_DIR/"
    done
    if [ -n "$SHARED_FOLDER" ]; then
        # Artwork Jellyfin copied into the shared folder belongs to the most recently
        # started recording of this program. Take it only when no other recording is
        # still in the folder; otherwise it is the sibling's.
        if ! compgen -G "$SHARED_FOLDER/*.ts" >/dev/null && ! compgen -G "$SHARED_FOLDER/*.mkv" >/dev/null; then
            for f in "$SHARED_FOLDER"/poster.* "$SHARED_FOLDER"/fanart.* "$SHARED_FOLDER"/landscape.* "$SHARED_FOLDER"/logo.*; do
                [ -e "$f" ] && mv "$f" "$DEST_DIR/"
            done
        else
            log "Another recording is still in $SHARED_FOLDER; leaving its artwork in place."
        fi
        rmdir "$SHARED_FOLDER" 2>/dev/null && log "Removed empty shared folder: $SHARED_FOLDER"
    fi
    log "Moved recording to its own folder: $DEST_DIR"
fi

exit 0
