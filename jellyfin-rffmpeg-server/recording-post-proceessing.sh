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
ART_STAGE="$(mktemp -d "${TEMP_DIR}/artwork.XXXXXX")"
trap 'rm -f "$LOCK_FILE"; rm -rf "$ART_STAGE"' EXIT

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
read_timer() {
    CHANNEL_ID=""
    PROGRAM_ID=""
    OWNS_SHARED_ART=0
    while IFS='=' read -r key value; do
        case "$key" in
            CHANNEL_ID|PROGRAM_ID|OWNS_SHARED_ART) printf -v "$key" '%s' "${value%$'\r'}" ;;
        esac
    done < <("$PYTHON_BIN" "$METADATA_HELPER" timer "$INPUT_FILE" 2>> "$LOG_FILE")
}
read_timer

GOT_ART=0
if [ -z "$PROGRAM_ID" ]; then
    log "No Jellyfin timer found for this recording; using file name only."
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
# folder (<root>/<program name>/), so they show as one item with one poster,
# and copies each recording's artwork into that folder when it starts,
# overwriting the previous recording's. Move the finished recording and its
# .nfo into a folder of its own and give it its own program's artwork. Series
# recordings (Season folders) keep Jellyfin's layout; their artwork is already
# saved per recording.
#
# Another same-name recording may have started while comskip ran and replaced
# the shared artwork, so ownership is re-read now. If that read fails, keep the
# first read's channel and program but claim nothing.
FIRST_CHANNEL_ID="$CHANNEL_ID"
FIRST_PROGRAM_ID="$PROGRAM_ID"
read_timer
if [ -z "$PROGRAM_ID" ] && [ -n "$FIRST_PROGRAM_ID" ]; then
    log "Timer re-read failed; not claiming shared artwork."
    CHANNEL_ID="$FIRST_CHANNEL_ID"
    PROGRAM_ID="$FIRST_PROGRAM_ID"
    OWNS_SHARED_ART=0
fi
PARENT_DIR="$(dirname "$FINAL_FILE")"
PARENT_NAME="$(basename "$PARENT_DIR")"

# Programs airing at the same time are on different channels, so the channel
# makes the folder unique even when two recordings share a name and start time.
FOLDER_NAME="$INPUT_BASENAME"
if [ -n "$CHANNEL_ID" ]; then
    FOLDER_NAME="${INPUT_BASENAME} [$(printf '%s' "$CHANNEL_ID" | tr -c 'A-Za-z0-9_.-' '_')]"
fi

if [ ! -f "$FINAL_FILE" ]; then
    log "Final file not found; skipping folder move: $FINAL_FILE"
elif [ "$PARENT_NAME" = "$FOLDER_NAME" ] || [ "$PARENT_NAME" = "$INPUT_BASENAME" ] \
        || [[ "$PARENT_NAME" =~ ^"$FOLDER_NAME"\ \([0-9]+\)$ ]]; then
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

    mkdir -p "$DEST_DIR"
    mv "$FINAL_FILE" "$DEST_DIR/"
    # Sidecars written by Jellyfin for this recording (.nfo, -thumb.jpg, ...).
    for f in "$PARENT_DIR/$INPUT_BASENAME".* "$PARENT_DIR/$INPUT_BASENAME"-*; do
        [ -e "$f" ] && mv "$f" "$DEST_DIR/"
    done
    log "Moved recording to its own folder: $DEST_DIR"

    # Artwork: this recording's own program from Jellyfin's guide first. The
    # shared folder's copy is used only when it is this recording's, i.e. this
    # recording started last of those written into the folder.
    if [ "$GOT_ART" = "1" ]; then
        mv "$ART_STAGE"/* "$DEST_DIR/"
    fi

    if [ -n "$SHARED_FOLDER" ]; then
        if [ -n "$PROGRAM_ID" ]; then
            # Owned art always leaves the shared folder now (kept if the guide had
            # none, else dropped), so no other recording can pick it up later.
            CLAIM="$OWNS_SHARED_ART"
        elif ! compgen -G "$SHARED_FOLDER/*.ts" >/dev/null && ! compgen -G "$SHARED_FOLDER/*.mkv" >/dev/null; then
            # No timer: the art is this recording's only if no other recording is here.
            CLAIM=1
        else
            CLAIM=0
        fi

        if [ "$CLAIM" = "1" ]; then
            for f in "$SHARED_FOLDER"/poster.* "$SHARED_FOLDER"/fanart.* "$SHARED_FOLDER"/landscape.* "$SHARED_FOLDER"/logo.*; do
                [ -e "$f" ] || continue
                if [ "$GOT_ART" = "1" ]; then
                    rm -f "$f"
                else
                    mv "$f" "$DEST_DIR/"
                fi
            done
            [ "$GOT_ART" = "0" ] && compgen -G "$DEST_DIR/poster.*" >/dev/null && log "Took this recording's artwork from $SHARED_FOLDER."
        else
            log "Artwork in $SHARED_FOLDER is not this recording's; leaving it."
        fi
        rmdir "$SHARED_FOLDER" 2>/dev/null && log "Removed empty shared folder: $SHARED_FOLDER"
    fi
fi

exit 0
