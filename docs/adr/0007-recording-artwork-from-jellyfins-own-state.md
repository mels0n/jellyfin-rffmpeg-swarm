# 7. Give each recording its own artwork from Jellyfin's own state, without an API key

Status: Accepted
Date: 2026-10-22

## Context
Jellyfin records every non-series program of the same name into one folder and, when each
recording starts, copies that program's artwork into it, overwriting the previous one's.
Two overlapping games with the same guide title therefore share, and lose, artwork. The
post-processor is given only the file path, and the image must work with no setup beyond
the compose file.

## Decision
Use what Jellyfin already records. The recording's completed timer in
`data/livetv/timers.json` names its channel and guide program; the program is looked up
read-only in `jellyfin.db` by `ExternalId`, and its images are downloaded from the server's
own anonymous image endpoint on `127.0.0.1`, before comskip runs. Each recording moves to
`<file name> [<channel id>]`, which is unique because programs airing at once are on
different channels.

## Alternatives rejected
- **The Jellyfin API with a key:** every user would have to create and pass in a key.
- **Reuse the artwork Jellyfin copied into the shared folder:** nothing records whose it
  is, and working it out from timers or timestamps fails for late starts, restarts and
  programs without images.
- **Make guide titles unique in the XMLTV source:** changes how every program looks in the
  guide to fix a storage detail, and depends on the provider.

## Consequences
A recording gets its program's guide artwork or, if the guide no longer has it, Jellyfin's
frame grab; it never gets another recording's. The lookup depends on the `timers.json`
layout, the `BaseItems` table and the server answering on `127.0.0.1`, so any failure falls
back to the frame grab and is logged. The shared folder's artwork is deleted once no
recording is left in it.
