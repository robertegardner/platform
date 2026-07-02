#!/usr/bin/env python3
"""wxsat_live_relay.py — mirror the Pi's live-pass telemetry to the rack (.84).

The tuner's /api/wxsat/live reads /run/sdr-streams/wxsat_live.json and treats
frames older than 8 s as {live:false}. During a Pi-local capture the sidecar
runs ON THE PI, so this daemon polls the Pi's wxsat-http and forwards only
FRESH live frames to that same path — the UI is unchanged, and while the
rack-side decode phase runs, the rack's own sidecar owns the file (we only
write frames the Pi stamped in the last 8 s, so the two never fight).

It ALSO mirrors the Pi scheduler's wxsat_status.json (state scheduled/
capturing/idle) to /run/sdr-streams/wxsat_status.json — that file drives the
"capturing" badge on /wxsat and the dashboard Meteor tile, and the Pi is its
authoritative writer now. wxsat-sync only writes it when the Pi is
unreachable (so an outage degrades to the rack's own forecast instead of a
stale "capturing").
"""
import json
import os
import time
import urllib.request

PI_BASE = os.environ.get("WXSAT_PI_LIVE_BASE", "")
if not PI_BASE:
    # Back-compat: derive from the full live URL if only that is set.
    url = os.environ.get("WXSAT_PI_LIVE_URL",
                         "http://goes.srvr:8078/live/wxsat_live.json")
    PI_BASE = url.rsplit("/", 1)[0]
LIVE_DST = os.environ.get("WXSAT_LIVE_PATH", "/run/sdr-streams/wxsat_live.json")
STATUS_DST = os.environ.get("WXSAT_STATUS_PATH",
                            "/run/sdr-streams/wxsat_status.json")
POLL_S = float(os.environ.get("WXSAT_RELAY_POLL_S", "1.5"))


def fetch(name):
    with urllib.request.urlopen(f"{PI_BASE}/{name}", timeout=2) as r:
        return json.loads(r.read())


def write(path, data):
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        json.dump(data, f)
    os.replace(tmp, path)


last_status_written = 0.0
while True:
    try:
        live = fetch("wxsat_live.json")
        if time.time() - live.get("updated", 0) <= 8:
            write(LIVE_DST, live)
    except Exception:
        pass  # link down / no capture running — nothing to relay
    try:
        # Status changes rarely (scheduled/capturing transitions) — mirror it
        # every ~10 s, not every poll.
        if time.time() - last_status_written >= 10:
            status = fetch("wxsat_status.json")
            if isinstance(status, dict) and status.get("state"):
                write(STATUS_DST, status)
                last_status_written = time.time()
    except Exception:
        pass  # Pi unreachable — wxsat-sync's fallback status takes over
    time.sleep(POLL_S)
