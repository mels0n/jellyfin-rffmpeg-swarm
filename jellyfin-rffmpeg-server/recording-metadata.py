#!/usr/bin/env python3
"""Per-recording facts and artwork for the DVR post-processor.

Before running the post-processor, Jellyfin saves the recording's timer in
timers.json as Completed, with RecordingPath set to the path it hands the
post-processor. That timer names the channel and the guide program
(ProgramId), which Jellyfin looks up by ExternalId to find the program's
artwork. This helper does the same lookups, read-only, so the post-processor
needs no API key and nothing leaves the host.

Usage:
  recording-metadata.py timer <recording path>
      Prints CHANNEL_ID=... and PROGRAM_ID=... for the timer that produced
      <recording path>. Exits 1 (prints nothing) when no timer matches.

  recording-metadata.py artwork <program id> <destination dir>
      Saves the program's Primary, Thumb, Backdrop and Logo images as poster,
      landscape, fanart and logo (the names Jellyfin uses for non-series
      recordings). Prints the number of images saved. Exits 1 when none were.

  recording-metadata.py clean-shared <folder>
      Removes the artwork Jellyfin copied into a shared program folder, and
      then the folder, once nothing but that artwork is left in it.

Paths are overridable for testing: RECMETA_CONFIG_DIR (default /config), or
individually RECMETA_TIMERS_FILE, RECMETA_JELLYFIN_DB, RECMETA_NETWORK_CONFIG,
RECMETA_JELLYFIN_URL.
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

CONFIG_DIR = os.environ.get("RECMETA_CONFIG_DIR", "/config")
TIMERS_FILE = os.environ.get("RECMETA_TIMERS_FILE", os.path.join(CONFIG_DIR, "data/livetv/timers.json"))
JELLYFIN_DB = os.environ.get("RECMETA_JELLYFIN_DB", os.path.join(CONFIG_DIR, "data/jellyfin.db"))
NETWORK_CONFIG = os.environ.get("RECMETA_NETWORK_CONFIG", os.path.join(CONFIG_DIR, "config/network.xml"))

# Image type -> file name, matching Jellyfin's naming for non-series recordings.
IMAGE_NAMES = (("Primary", "poster"), ("Thumb", "landscape"), ("Backdrop", "fanart"), ("Logo", "logo"))
EXTENSIONS = {"image/jpeg": ".jpg", "image/png": ".png", "image/webp": ".webp", "image/gif": ".gif"}

# Per-request socket timeout and a budget for the whole fetch.
REQUEST_TIMEOUT = 20
FETCH_BUDGET = 60


def clean_field(value):
    """A timer field as a single-line string, or "" if it is anything else."""
    if not isinstance(value, str) or re.search(r"[\x00-\x1f\x7f]", value):
        return ""
    return value


def load_timers():
    # Jellyfin rewrites the file in place; a read that lands mid-write is retried once.
    for attempt in range(2):
        try:
            with open(TIMERS_FILE, encoding="utf-8-sig") as f:
                timers = json.load(f)
            return timers if isinstance(timers, list) else []
        except ValueError:  # JSONDecodeError, or a multi-byte character cut in half
            if attempt:
                raise
            time.sleep(1)
    return []


def timer_command(recording_path):
    timer = next(
        (t for t in load_timers() if isinstance(t, dict) and t.get("RecordingPath") == recording_path),
        None,
    )
    if timer is None:
        return 1
    print(f"CHANNEL_ID={clean_field(timer.get('ChannelId'))}")
    print(f"PROGRAM_ID={clean_field(timer.get('ProgramId'))}")
    return 0


def jellyfin_url():
    url = os.environ.get("RECMETA_JELLYFIN_URL")
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


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):
        return None


def read_within(resp, deadline):
    """The response body, giving up once the fetch budget is used up."""
    chunks = []
    while True:
        if time.monotonic() > deadline:
            raise TimeoutError("fetch budget used up mid-download")
        chunk = resp.read(65536)
        if not chunk:
            return b"".join(chunks)
        chunks.append(chunk)


def artwork_command(program_id, dest_dir):
    if not os.path.isdir(dest_dir):
        print(f"artwork destination is not a directory: {dest_dir!r}", file=sys.stderr)
        return 1
    try:
        item_id = program_item_id(program_id)
    except sqlite3.Error as e:
        print(f"database lookup failed: {e}", file=sys.stderr)
        return 1
    if not item_id:
        print("program not in guide", file=sys.stderr)
        return 1

    # Loopback only: no proxy from the environment, no redirects to other hosts.
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect)
    base = jellyfin_url()
    deadline = time.monotonic() + FETCH_BUDGET
    saved = 0
    for image_type, name in IMAGE_NAMES:
        if time.monotonic() > deadline:
            print(f"{image_type}: skipped, fetch budget used up", file=sys.stderr)
            continue
        # Image requests need no authentication.
        url = f"{base}/Items/{item_id}/Images/{image_type}"
        try:
            with opener.open(url, timeout=REQUEST_TIMEOUT) as resp:
                content_type = resp.headers.get_content_type()
                data = read_within(resp, deadline)
        except urllib.error.HTTPError as e:
            if e.code != 404:  # 404 = the program has no image of this type
                print(f"{image_type}: HTTP {e.code}", file=sys.stderr)
            continue
        except (urllib.error.URLError, http.client.HTTPException, OSError, TimeoutError) as e:
            print(f"{image_type}: {type(e).__name__}: {e}", file=sys.stderr)
            continue
        ext = EXTENSIONS.get(content_type)
        if not ext or not data:
            print(f"{image_type}: unusable response ({content_type}, {len(data)} bytes)", file=sys.stderr)
            continue
        for old in os.listdir(dest_dir):
            if os.path.splitext(old)[0] == name:
                os.remove(os.path.join(dest_dir, old))
        with open(os.path.join(dest_dir, name + ext), "wb") as f:
            f.write(data)
        saved += 1

    print(saved)
    return 0 if saved else 1


def clean_shared_command(folder):
    try:
        entries = os.listdir(folder)
    except OSError:
        return 0
    stems = {name for _, name in IMAGE_NAMES}
    if any(os.path.splitext(e)[0] not in stems for e in entries):
        return 0  # anything besides the artwork means the folder is still in use
    for e in entries:
        try:
            os.remove(os.path.join(folder, e))
        except OSError as err:
            print(f"could not remove {e}: {err}", file=sys.stderr)
    try:
        os.rmdir(folder)
        print(f"removed {folder}")
    except OSError:
        pass  # something else is in it
    return 0


def main(argv):
    if len(argv) == 3 and argv[1] == "timer":
        return timer_command(argv[2])
    if len(argv) == 4 and argv[1] == "artwork":
        return artwork_command(argv[2], argv[3])
    if len(argv) == 3 and argv[1] == "clean-shared":
        return clean_shared_command(argv[2])
    print(__doc__, file=sys.stderr)
    return 2


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv))
    except Exception as e:  # report and fall back; never a traceback in the log
        print(f"error: {type(e).__name__}: {e}", file=sys.stderr)
        sys.exit(1)
