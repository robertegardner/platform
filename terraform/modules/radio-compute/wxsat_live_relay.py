#!/usr/bin/env python3
"""wxsat_live_relay.py — mirror the Pi's live-pass telemetry to the rack (.84).

The tuner's /api/wxsat/live reads /run/sdr-streams/wxsat_live.json and treats
frames older than 8 s as {live:false}. During a Pi-local capture the sidecar
runs ON THE PI, so this daemon polls the Pi's wxsat-http and forwards only
FRESH frames to that same path — the UI is unchanged, and while the rack-side
decode phase runs, the rack's own sidecar owns the file (we only write frames
the Pi stamped in the last 8 s, so the two never fight).
"""
import json
import os
import time
import urllib.request

SRC = os.environ.get("WXSAT_PI_LIVE_URL",
                     "http://goes.srvr:8078/live/wxsat_live.json")
DST = os.environ.get("WXSAT_LIVE_PATH", "/run/sdr-streams/wxsat_live.json")
POLL_S = float(os.environ.get("WXSAT_RELAY_POLL_S", "1.5"))

while True:
    try:
        with urllib.request.urlopen(SRC, timeout=2) as r:
            data = json.loads(r.read())
        if time.time() - data.get("updated", 0) <= 8:
            tmp = DST + ".tmp"
            with open(tmp, "w") as f:
                json.dump(data, f)
            os.replace(tmp, DST)
    except Exception:
        pass  # link down / no capture running — nothing to relay
    time.sleep(POLL_S)
