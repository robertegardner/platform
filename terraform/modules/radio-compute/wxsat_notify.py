#!/usr/bin/env python3
"""Best-effort ntfy push for wxsat (Meteor) pass + decode events.

Stdlib only (mirrors dashboard.py / wx_alert.py). Reads NTFY_URL + NTFY_TOPIC
from the environment; a POST failure or missing config NEVER raises — a down
ntfy must never break a capture.
"""
import logging
import os
import urllib.request

log = logging.getLogger("wxsat.notify")


def notify(event, title, message, priority="default", tags=""):
    base = (os.environ.get("NTFY_URL") or "").rstrip("/")
    topic = os.environ.get("NTFY_TOPIC") or ""
    if not base or not topic:
        return False
    try:
        req = urllib.request.Request(
            f"{base}/{topic}",
            data=message.encode("utf-8"),
            method="POST",
            headers={
                "Title": title,
                "Priority": priority,
                "Tags": tags,
                "User-Agent": "wxsat-notify/1.0",  # non-default UA (some proxies 403 urllib)
            },
        )
        with urllib.request.urlopen(req, timeout=8):
            pass
        return True
    except Exception as e:  # noqa: BLE001 — best-effort
        log.warning("ntfy %s failed: %s", event, e)
        return False
