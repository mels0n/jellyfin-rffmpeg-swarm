# 7. Give each recording its own artwork from Jellyfin's own state, without an API key

Status: Accepted
Date: 2026-10-22

## Context
Jellyfin records every non-series program of the same name into one folder and copies the
program's artwork into it as `poster.jpg`, `landscape.jpg`, `fanart.jpg` and `logo.jpg`
when each recording starts, overwriting the previous recording's. When two different games
with the same guide title overlap, the earlier game's artwork is lost, and moving the
shared folder's artwork after the fact cannot tell whose it is. The post-processor is only
given the file path, and the image must work with no setup beyond the compose file.

## Decision
Use what Jellyfin already records. Before running the post-processor, Jellyfin saves the
recording's timer in `data/livetv/timers.json` as completed, with `RecordingPath` set to
the path it passes in; the timer names the channel and the guide program. The post-processor looks
that program up read-only in `jellyfin.db` by `ExternalId`, the same lookup Jellyfin uses,
and downloads its images from the server's own image endpoint on `127.0.0.1`, which needs
no authentication. The images are fetched before the long comskip run, because the guide
drops a program soon after it airs. Folders are named `<file name> [<channel id>]`, since
two programs airing at once are on different channels.

## Alternatives rejected
- **The Jellyfin API with a key.** Needs a key created and passed in by each user, which
  breaks the zero-configuration goal.
- **Work out the owner of the shared artwork from file order or timestamps.** Jellyfin
  copies cached images, so timestamps do not reflect when a recording started, and finish
  order is not start order.
- **Rewrite guide titles upstream (in the XMLTV source) to make folders unique.** Changes
  how every program looks in the guide to fix a storage detail, and depends on the guide
  provider.

## Consequences
Each recording gets its own program's artwork even when same-title recordings overlap. The
lookup depends on two Jellyfin internals, the `timers.json` layout and the `BaseItems`
table, and on the server answering on `127.0.0.1`. Any failure falls back to the shared
folder's artwork only when the timers show this recording started strictly after every
other recording in that folder (ownership is re-checked after comskip, and a tie counts as
not owned), and otherwise to Jellyfin's frame grab; the log says which was used.
Recordings whose timer cannot be found keep the previous file-name folder.
