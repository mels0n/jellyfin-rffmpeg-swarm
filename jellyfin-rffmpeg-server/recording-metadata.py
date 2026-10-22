#!/usr/bin/env python3
"""Per-recording facts and artwork for the DVR post-processor.

Before running the post-processor, Jellyfin saves the recording's timer in
timers.json as Completed, with RecordingPath set to the path it hands the
post-processor (completed timers are kept). That timer names the guide program
(ProgramId), which Jellyfin looks up by ExternalId to find the program's
artwork. This helper does the same lookups, read-only, so the post-processor
needs no API key and nothing leaves the host.

Usage:
  recording-metadata.py timer <recording path>
      Prints KEY=VALUE lines for the timer that produced <recording path>:
        CHANNEL_ID, PROGRAM_ID, START_DATE
        OWNS_SHARED_ART  1 if this recording started strictly after every other
                         recording written into its folder, so the artwork
                         Jellyfin copied into that folder is this recording's;
                         else 0
      Exits 1 (prints nothing) when no timer matches.

  recording-metadata.py artwork <program id> <destination dir>
      Saves the program's Primary, Thumb, Backdrop and Logo images as poster,
      landscape, fanart and logo (the names Jellyfin uses for non-series
      recordings). Prints the number of images saved. Exits 1 when none were.

Paths are overridable for testing: TIMERS_FILE, JELLYFIN_DB, NETWORK_CONFIG,
JELLYFIN_URL.
"""

import http.client
import json
import os
import re
import sqlite3
import sys
import time
import urllib.error
import urllib.request
from datetime import datetime, timedelta

TIMERS_FILE = os.environ.get("TIMERS_FILE", "/config/data/livetv/timers.json")
JELLYFIN_DB = os.environ.get("JELLYFIN_DB", "/config/data/jellyfin.db")
NETWORK_CONFIG = os.environ.get("NETWORK_CONFIG", "/config/config/network.xml")

# Image type -> file name, matching Jellyfin's naming for non-series recordings.
IMAGE_NAMES = (("Primary", "poster"), ("Thumb", "landscape"), ("Backdrop", "fanart"), ("Logo", "logo"))
EXTENSIONS = {"image/jpeg": ".jpg", "image/png": ".png", "image/webp": ".webp", "image/gif": ".gif"}


def load_timers():
    # Jellyfin rewrites the file in place; a read that lands mid-write is retried once.
    for attempt in range(2):
        try:
            with open(TIMERS_FILE, encoding="utf-8-sig") as f:
                timers = json.load(f)
            return timers if isinstance(timers, list) else []
        except json.JSONDecodeError:
            if attempt:
                raise
            time.sleep(1)
    return []


def name_key(name):
    """Program name reduced to letters and digits. Jellyfin replaces characters
    that are invalid in file names when it builds the folder, so names that
    differ only in punctuation can share a folder; matching loosely errs toward
    "not owned"."""
    return re.sub(r"[\W_]+", "", name or "").casefold()


def actual_start(t):
    """When the recording began: the program start minus its pre-padding."""
    value = re.sub(r"(\.\d{6})\d+", r"\1", t.get("StartDate") or "").replace("Z", "+00:00")
    try:
        start = datetime.fromisoformat(value)
    except ValueError:
        return None
    return start - timedelta(seconds=t.get("PrePaddingSeconds") or 0)


def timer_command(recording_path):
    timers = load_timers()
    timer = next((t for t in timers if t.get("RecordingPath") == recording_path), None)
    if timer is None:
        return 1

    # Jellyfin copies a program's artwork into the shared folder when its
    # recording starts, overwriting what is there, so the art belongs to the
    # recording that started last. Siblings: finished recordings in the same
    # folder (completed timers are kept) and same-name recordings still in
    # progress (their RecordingPath is only set when they finish).
    folder = os.path.dirname(recording_path)
    name = name_key(timer.get("Name"))
    siblings = [
        t for t in timers
        if t.get("Id") != timer.get("Id")
        and (
            (t.get("Status") == "Completed" and os.path.dirname(t.get("RecordingPath") or "") == folder)
            or (t.get("Status") == "InProgress" and name_key(t.get("Name")) == name)
            # A failed recording waits as New before retrying; its art is still here.
            or (t.get("Status") == "New" and (t.get("RetryCount") or 0) > 0 and name_key(t.get("Name")) == name)
        )
    ]
    mine = actual_start(timer)
    # Any doubt (unknown start, a tie, a later start) means the art is not ours.
    owns = mine is not None and all(
        (s := actual_start(t)) is not None and s < mine for t in siblings
    )

    for key, value in (
        ("CHANNEL_ID", timer.get("ChannelId") or ""),
        ("PROGRAM_ID", timer.get("ProgramId") or ""),
        ("START_DATE", timer.get("StartDate") or ""),
        ("OWNS_SHARED_ART", "1" if owns else "0"),
    ):
        print(f"{key}={value}")
    return 0


def jellyfin_url():
    url = os.environ.get("JELLYFIN_URL")
    if url:
        return url.rstrip("/")
    port, base = "8096", ""
    try:
        with open(NETWORK_CONFIG, encoding="utf-8-sig") as f:
            text = f.read()
        m = re.search(r"<InternalHttpPort>(\d+)</InternalHttpPort>", text)
        port = m.group(1) if m else port
        m = re.search(r"<BaseUrl>([^<]*)</BaseUrl>", text)
        base = m.group(1).strip().strip("/") if m else ""
    except OSError:
        pass
    return f"http://127.0.0.1:{port}" + (f"/{base}" if base else "")


def program_item_id(program_id):
    # Read-only: the database belongs to the running server.
    con = sqlite3.connect(f"file:{JELLYFIN_DB}?mode=ro", uri=True, timeout=10)
    try:
        row = con.execute(
            "SELECT Id FROM BaseItems WHERE ExternalId = ? AND Type = 'MediaBrowser.Controller.LiveTv.LiveTvProgram' LIMIT 1",
            (program_id,),
        ).fetchone()
    finally:
        con.close()
    return str(row[0]) if row else None


def artwork_command(program_id, dest_dir):
    try:
        item_id = program_item_id(program_id)
    except sqlite3.Error as e:
        print(f"database lookup failed: {e}", file=sys.stderr)
        return 1
    if not item_id:
        print("program not in guide", file=sys.stderr)
        return 1

    base = jellyfin_url()
    saved = 0
    for image_type, name in IMAGE_NAMES:
        # Image requests need no authentication.
        url = f"{base}/Items/{item_id}/Images/{image_type}"
        try:
            with urllib.request.urlopen(url, timeout=30) as resp:
                ext = EXTENSIONS.get(resp.headers.get_content_type())
                data = resp.read()
        except (urllib.error.URLError, http.client.HTTPException, OSError):
            continue  # 404 = the program has no image of this type
        if not ext or not data:
            continue
        for old in os.listdir(dest_dir):
            if os.path.splitext(old)[0] == name:
                os.remove(os.path.join(dest_dir, old))
        with open(os.path.join(dest_dir, name + ext), "wb") as f:
            f.write(data)
        saved += 1

    print(saved)
    return 0 if saved else 1


def main(argv):
    if len(argv) == 3 and argv[1] == "timer":
        return timer_command(argv[2])
    if len(argv) == 4 and argv[1] == "artwork":
        return artwork_command(argv[2], argv[3])
    print(__doc__, file=sys.stderr)
    return 2


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv))
    except Exception as e:  # report and fall back; never a traceback in the log
        print(f"error: {type(e).__name__}: {e}", file=sys.stderr)
        sys.exit(1)
