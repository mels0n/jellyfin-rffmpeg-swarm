#!/bin/bash

# Jellyfin DVR post-processor.
#   1. Runs comskip on the recording and keeps its log in Jellyfin's log folder
#      (comskip_<date>_<recording>.log), where Jellyfin's log retention prunes it.
#   2. Runs comchap (chapters, default) or comcut (remove commercials) on the EDL.
#   3. Moves the finished recording into a folder of its own so each recording
#      shows as its own item, and saves that program's artwork into it.
#      Series recordings are left alone.
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
PYTHON_BIN="${PYTHON_BIN:-python3}"
METADATA_HELPER="${METADATA_HELPER:-/recording-metadata.py}"

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
ART_STAGE="$(mktemp -d "${TEMP_DIR}/artwork.XXXXXX")" || ART_STAGE=""
trap 'rm -f "$LOCK_FILE"; [ -n "$ART_STAGE" ] && rm -rf "$ART_STAGE"' EXIT

# unique_path <path>: <path>, or "<name> - N.<ext>" if it is taken, so a file
# is never moved onto another recording.
unique_path() {
    local path="$1" n=1
    while [ -e "$path" ]; do
        path="${1%.*} - ${n}.${1##*.}"
        ((n++))
    done
    printf '%s' "$path"
}

log "----------------------------------------------------"
log "Processing request for: $INPUT_FILE"
date >> "$LOG_FILE"
log "Action: $COMMAND"
log "Using INI file: $COMSKIP_INI"

# Final output path. Chaptered output is always MKV.
OUTPUT_FILE="${INPUT_FILE%.*}.mkv"
INPUT_BASENAME="$(basename "${INPUT_FILE%.*}")"

# --- Recording facts and artwork ---
# Jellyfin saves this recording's timer before running this script; it names the
# channel and guide program (see recording-metadata.py). The guide drops a program
# soon after it airs, so its artwork is fetched now, before the long comskip run,
# and placed with the recording at the end.
CHANNEL_ID=""
PROGRAM_ID=""
while IFS='=' read -r key value; do
    case "$key" in
        CHANNEL_ID|PROGRAM_ID) printf -v "$key" '%s' "${value%$'\r'}" ;;
    esac
done < <("$PYTHON_BIN" "$METADATA_HELPER" timer "$INPUT_FILE" 2>> "$LOG_FILE")

GOT_ART=0
if [ -z "$PROGRAM_ID" ]; then
    log "No Jellyfin timer found for this recording; using file name only."
elif [ -z "$ART_STAGE" ]; then
    log "Could not create an artwork staging directory in $TEMP_DIR; skipping artwork."
elif SAVED=$("$PYTHON_BIN" "$METADATA_HELPER" artwork "$PROGRAM_ID" "$ART_STAGE" 2>> "$LOG_FILE"); then
    GOT_ART=1
    log "Fetched ${SAVED%$'\r'} image(s) for guide program $PROGRAM_ID."
else
    log "Guide program artwork unavailable for $PROGRAM_ID."
fi

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

# Puts the unprocessed recording back. While it was away a new recording may
# have taken its name, or its now-empty folder may have been removed.
restore_input() {
    mkdir -p "$(dirname "$INPUT_FILE")"
    FINAL_FILE="$(unique_path "$INPUT_FILE")"
    if ! mv "$TEMP_INPUT_FILE" "$FINAL_FILE"; then
        log "ERROR: could not move the recording back to $FINAL_FILE; it is at $TEMP_INPUT_FILE."
        rm -f "${TEMP_INPUT_FILE%.*}".{edl,log,logo.txt,txt,ffmeta}
        exit 1
    fi
}

if [ ! -s "$COMSKIP_EDL" ]; then
    # Nothing to chapter or cut. Keep the original recording as is.
    log "No commercials found (comskip exit code $COMSKIP_EXIT). Original file is unchanged."
    rm -f "${TEMP_INPUT_FILE%.*}".{edl,log,logo.txt,txt}
    restore_input
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
        # A re-recorded program can share this name with an earlier recording
        # that is already an .mkv here; never replace it.
        mkdir -p "$(dirname "$OUTPUT_FILE")"
        FINAL_FILE="$(unique_path "$OUTPUT_FILE")"
        [ "$FINAL_FILE" != "$OUTPUT_FILE" ] && log "$OUTPUT_FILE already exists; saving as $FINAL_FILE."
        mv "$TEMP_OUTPUT_FILE" "$FINAL_FILE"
        rm -f "$TEMP_INPUT_FILE"
    else
        log "ERROR: $COMMAND failed or created an empty file. Original file is unchanged."
        rm -f "$TEMP_OUTPUT_FILE"
        restore_input
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
# folder (<root>/<program name>/), so they show as one item with one poster,
# and copies each recording's artwork into that folder when it starts,
# overwriting the previous recording's. Move the finished recording and its
# .nfo into a folder of its own and give it its own program's artwork from the
# guide. The shared folder's copy is never used: it cannot tell whose it is.
# Series recordings (Season folders) keep Jellyfin's layout; their artwork is
# already saved per recording.
PARENT_DIR="$(dirname "$FINAL_FILE")"
PARENT_NAME="$(basename "$PARENT_DIR")"

# Programs airing at the same time are on different channels, so the channel
# makes the folder unique even when two recordings share a name and start time.
FOLDER_NAME="$INPUT_BASENAME"
if [ -n "$CHANNEL_ID" ]; then
    FOLDER_NAME="${INPUT_BASENAME} [$(printf '%s' "$CHANNEL_ID" | tr -c 'A-Za-z0-9_.-' '_')]"
fi
# Folders this script may already have made for this recording, with or without
# the channel and with or without a " (N)" suffix (unquoted: these are regexes).
OWN_FOLDER_SUFFIX=' \[[^]]*\]( \([0-9]+\))?$'
NUMBER_SUFFIX=' \([0-9]+\)$'

if [ ! -f "$FINAL_FILE" ]; then
    log "Final file not found; skipping folder move: $FINAL_FILE"
elif [ "$PARENT_NAME" = "$FOLDER_NAME" ] || [ "$PARENT_NAME" = "$INPUT_BASENAME" ] \
        || [[ "$PARENT_NAME" =~ ^"$INPUT_BASENAME"$OWN_FOLDER_SUFFIX ]] \
        || [[ "$PARENT_NAME" =~ ^"$INPUT_BASENAME"$NUMBER_SUFFIX ]]; then
    log "Recording already in its own folder."
elif [[ "$PARENT_NAME" =~ ^[Ss]eason ]] || [ -f "$PARENT_DIR/tvshow.nfo" ] || [ -f "$(dirname "$PARENT_DIR")/tvshow.nfo" ]; then
    log "Series recording; leaving folder layout to Jellyfin."
else
    if [ "$PARENT_DIR" = "$LIVETV_ROOT" ]; then
        DEST_BASE="${LIVETV_ROOT}/${FOLDER_NAME}"
        SHARED_FOLDER=""
    else
        DEST_BASE="$(dirname "$PARENT_DIR")/${FOLDER_NAME}"
        SHARED_FOLDER="$PARENT_DIR"
    fi

    # Never merge into a folder that already holds another recording.
    DEST_DIR="$DEST_BASE"
    n=2
    while [ -e "$DEST_DIR" ] && { [ ! -d "$DEST_DIR" ] || [ -n "$(ls -A "$DEST_DIR")" ]; }; do
        DEST_DIR="${DEST_BASE} (${n})"
        ((n++))
    done

    if ! mkdir -p "$DEST_DIR" || ! mv "$FINAL_FILE" "$DEST_DIR/"; then
        log "ERROR: could not move the recording to $DEST_DIR; leaving it at $FINAL_FILE."
        rmdir "$DEST_DIR" 2>/dev/null
        exit 0
    fi
    # Sidecars written by Jellyfin for this recording (.nfo, -thumb.jpg, ...).
    # Videos are skipped: a same-name video left here is another recording.
    for f in "$PARENT_DIR/$INPUT_BASENAME".* "$PARENT_DIR/$INPUT_BASENAME"-*; do
        case "${f,,}" in *.ts|*.mkv|*.mp4|*.m4v|*.avi) continue ;; esac
        [ -e "$f" ] && mv "$f" "$DEST_DIR/"
    done
    log "Moved recording to its own folder: $DEST_DIR"

    if [ "$GOT_ART" = "1" ]; then
        for f in "$ART_STAGE"/*; do
            [ -e "$f" ] && mv "$f" "$DEST_DIR/"
        done
    fi

    if [ -n "$SHARED_FOLDER" ]; then
        # Once no recording is left in the shared folder, its artwork is stale.
        "$PYTHON_BIN" "$METADATA_HELPER" clean-shared "$SHARED_FOLDER" 2>> "$LOG_FILE" | while read -r line; do
            log "Removed empty shared folder: ${line#removed }"
        done
    fi
fi

exit 0
