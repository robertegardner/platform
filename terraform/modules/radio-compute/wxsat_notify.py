#!/usr/bin/env python3
"""Best-effort ntfy push for wxsat (Meteor) pass + decode events.

Stdlib only (mirrors dashboard.py / wx_alert.py). Reads NTFY_URL + NTFY_TOPIC
from the environment; a POST failure or missing config NEVER raises — a down
ntfy must never break a capture. Transient rejections (429 — ntfy.sh
rate-limits by source IP and the whole homelab shares one — and 5xx) are
retried with backoff, honoring Retry-After: these pushes are rare and losing
one to a single unlucky moment is worse than the sync timer blocking ~1 min
(bit the FIRST-ever image push, 2026-07-02).
"""
import logging
import os
import time
import urllib.error
import urllib.request

log = logging.getLogger("wxsat.notify")

ATTEMPTS = 3
BACKOFF_S = (20, 40)          # sleep before retry 2, 3
RETRY_AFTER_CAP_S = 120


def _retry_delay(err, attempt):
    try:
        ra = int(err.headers.get("Retry-After", ""))
        return min(max(ra, 1), RETRY_AFTER_CAP_S)
    except (AttributeError, TypeError, ValueError):
        return BACKOFF_S[min(attempt, len(BACKOFF_S) - 1)]


def notify(event, title, message, priority="default", tags=""):
    base = (os.environ.get("NTFY_URL") or "").rstrip("/")
    topic = os.environ.get("NTFY_TOPIC") or ""
    if not base or not topic:
        return False
    for attempt in range(ATTEMPTS):
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
            if attempt:
                log.info("ntfy %s delivered on attempt %d", event, attempt + 1)
            return True
        except urllib.error.HTTPError as e:
            if e.code != 429 and e.code < 500:
                log.warning("ntfy %s failed: %s", event, e)
                return False
            if attempt + 1 < ATTEMPTS:
                delay = _retry_delay(e, attempt)
                log.warning("ntfy %s got %s — retrying in %ds", event, e.code, delay)
                time.sleep(delay)
            else:
                log.warning("ntfy %s failed after %d attempts: %s", event, ATTEMPTS, e)
        except Exception as e:  # noqa: BLE001 — best-effort
            if attempt + 1 < ATTEMPTS:
                delay = BACKOFF_S[min(attempt, len(BACKOFF_S) - 1)]
                log.warning("ntfy %s error (%s) — retrying in %ds", event, e, delay)
                time.sleep(delay)
            else:
                log.warning("ntfy %s failed after %d attempts: %s", event, ATTEMPTS, e)
    return False
