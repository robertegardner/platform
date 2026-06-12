#!/usr/bin/env python3
"""icy-pusher: now-playing -> Icecast ICY StreamTitle metadata.

Polls the radio backend's /api/now_playing (via radio.rg2.io, so it follows
the active backend across the V2 unpause) and, on change, pushes
"Artist - Title" (falling back to RDS PS, then the FCC call sign) to the
local Icecast admin metadata endpoint for every configured mount. Listeners
that request ICY metadata — the WiiM and other network streamers — display
it natively; clients that ignore ICY (the web <audio> element, the Android
app) are untouched.

Stdlib only. Config via /etc/icy-pusher.env (root-only — Icecast admin
password).
"""

import json
import os
import time
import urllib.error
import urllib.parse
import urllib.request

NOW_PLAYING_URL = os.environ.get("NOW_PLAYING_URL", "https://radio.rg2.io/api/now_playing")
ICECAST = os.environ.get("ICECAST_ADMIN", "http://127.0.0.1:8000")
ADMIN_USER = os.environ.get("ADMIN_USER", "admin")
ADMIN_PASS = os.environ["ADMIN_PASS"]
MOUNTS = os.environ.get("MOUNTS", "/fm.mp3 /fm-duck.mp3").split()
POLL_S = float(os.environ.get("POLL_S", "3"))

# While fm-duck reports "talk", the ducked mounts get a marker instead of the
# (stale) song title — the now-playing pipeline can't identify commercials, so
# the last song would otherwise linger on the WiiM display through the duck.
DUCK_STATE_FILE = os.environ.get("DUCK_STATE_FILE", "/run/fm-duck/state")
DUCK_MOUNTS = set(os.environ.get("DUCK_MOUNTS", "/fm-duck.mp3").split())
TALK_SUFFIX = os.environ.get("TALK_SUFFIX", "at commercial")
STATE_MAX_AGE_S = 180  # stale state file (fm-duck down) counts as music


def duck_is_talking():
    try:
        st = os.stat(DUCK_STATE_FILE)
        if time.time() - st.st_mtime > STATE_MAX_AGE_S:
            return False
        with open(DUCK_STATE_FILE) as f:
            return f.read().startswith("talk")
    except OSError:
        return False


def station_line(np):
    """Station identity: FCC call sign + freq, RDS PS fallback."""
    call = ((np.get("fcc") or {}).get("call") or "").strip()
    freq = (np.get("freq") or "").strip()
    if call:
        return "%s %s" % (call, freq) if freq else call
    ps = ((np.get("rds") or {}).get("ps") or "").strip()
    return ps or "FM Radio"


def song_line(np):
    """Best 'now playing' line from the now_playing payload."""
    track = np.get("track") or {}
    artist = (track.get("artist") or "").strip()
    title = (track.get("title") or "").strip()
    if artist or title:
        return " - ".join(x for x in (artist, title) if x)
    rds = np.get("rds") or {}
    for fallback in (rds.get("artist"), rds.get("title")):
        if fallback and fallback.strip():
            a = (rds.get("artist") or "").strip()
            t = (rds.get("title") or "").strip()
            return " - ".join(x for x in (a, t) if x)
    return station_line(np)


def push(mount, song):
    qs = urllib.parse.urlencode(
        {"mode": "updinfo", "mount": mount, "song": song, "charset": "UTF-8"}
    )
    req = urllib.request.Request("%s/admin/metadata?%s" % (ICECAST, qs))
    auth = "%s:%s" % (ADMIN_USER, ADMIN_PASS)
    req.add_header(
        "Authorization",
        "Basic " + __import__("base64").b64encode(auth.encode()).decode(),
    )
    try:
        with urllib.request.urlopen(req, timeout=5):
            return True
    except urllib.error.HTTPError as e:
        # 400 = mount currently has no source (stream down/tuning) — normal.
        if e.code != 400:
            print("icy-pusher: %s push failed: %s" % (mount, e), flush=True)
        return False
    except OSError as e:
        print("icy-pusher: %s push failed: %s" % (mount, e), flush=True)
        return False


def main():
    # Latch per mount: a mount that (re)connects late — fm-duck restarts on
    # every upstream tune — gets the current title on the next poll instead
    # of waiting for the next song change.
    last = dict.fromkeys(MOUNTS)
    print("icy-pusher: %s -> %s on %s" % (NOW_PLAYING_URL, ICECAST, ", ".join(MOUNTS)), flush=True)
    while True:
        try:
            with urllib.request.urlopen(NOW_PLAYING_URL, timeout=5) as r:
                np = json.load(r)
            song = song_line(np)
            # Ducked mounts show the station instead of the (stale) song —
            # e.g. "KGMO 100.7 at commercial".
            marker = "%s %s" % (station_line(np), TALK_SUFFIX)
            talking = duck_is_talking()
            ok = []
            for m in MOUNTS:
                desired = marker if (talking and m in DUCK_MOUNTS) else song
                if last[m] != desired and push(m, desired):
                    last[m] = desired
                    ok.append("%s(%s)" % (m, "marker" if desired == marker and talking else "title"))
            if ok:
                print('icy-pusher: "%s" -> %s' % (song, ", ".join(ok)), flush=True)
        except (OSError, ValueError) as e:
            print("icy-pusher: now_playing poll failed: %s" % e, flush=True)
            last = dict.fromkeys(MOUNTS)  # re-push once the backend returns
        time.sleep(POLL_S)


if __name__ == "__main__":
    main()
