#!/usr/bin/env python3
"""dashboard.py — unified platform landing page + status aggregator (home.rg2.io).

The platform has grown to ~7 independent web surfaces (radio, scanner, GOES,
weather, ADS-B, Icecast …), each its own origin with no common front door. This
service is that front door: a Material-Design-3 (dark) page with one rich, live
tile per service domain, each showing real-time status + an embedded preview and
a button to open the service's full UI.

WHY a server-side aggregator (not browser fetch): the page is served over HTTPS
(via NPMplus) but every backend status API is plain HTTP on the Server VLAN, so a
browser on https://home.rg2.io cannot fetch() http://192.168.6.x (mixed-content
block) even though the backends send Access-Control-Allow-Origin: *. So a
background thread polls all backends server-side and the page reads ONE
same-origin aggregate (GET /api/dashboard). The GOES thumbnail is likewise
proxied through this origin (GET /api/proxy/goes-latest.png). Audio plays from the
already-TLS https://icecast.rg2.io URL, so no mixed content there.

Stdlib only (mirrors goes_gallery.py / wx_alert.py). Config via env (see
/etc/dashboard/dashboard.env). Every backend poll is wrapped + timeout-bounded;
one slow/down backend never blocks the page — its tile degrades to "unknown".
"""
import json
import os
import threading
import time
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlsplit

# ---- Config ---------------------------------------------------------------
PORT = int(os.environ.get("DASH_PORT", "8080"))
SITE_TITLE = os.environ.get("DASH_TITLE", "rg2.io platform")
POLL_INTERVAL = int(os.environ.get("DASH_POLL_INTERVAL", "15"))
TIMEOUT = float(os.environ.get("DASH_TIMEOUT", "2.5"))

# Backend bases (HTTP, on the Server VLAN — polled server-side).
RADIO_BASE = os.environ.get("DASH_RADIO_BASE", "http://192.168.6.84:8080")
SCANNER_BASE = os.environ.get("DASH_SCANNER_BASE", "http://192.168.6.83:8081")
GOES_BASE = os.environ.get("DASH_GOES_BASE", "http://192.168.6.85:8095")
WX_BASE = os.environ.get("DASH_WX_BASE", "http://192.168.6.84:8090")
WEATHER_BASE = os.environ.get("DASH_WEATHER_BASE", "http://192.168.6.87")
ADSB_BASE = os.environ.get("DASH_ADSB_BASE", "http://192.168.6.86:8080")
ICECAST_BASE = os.environ.get("DASH_ICECAST_BASE", "http://192.168.6.82:8000")
COMICS_BASE = os.environ.get("DASH_COMICS_BASE", "http://192.168.6.89:8080")

# Public "open" URLs (the dive-in target for each tile). TLS, via NPMplus.
OPEN_RADIO = os.environ.get("DASH_OPEN_RADIO", "https://radio.rg2.io/dash")
OPEN_SCANNER = os.environ.get("DASH_OPEN_SCANNER", "https://ems.rg2.io")
OPEN_GOES = os.environ.get("DASH_OPEN_GOES", "https://goes.rg2.io")
# GOES dish-aiming/peaking tool (goes-aim.service on the GOES Pi, LAN-only HTTP).
OPEN_GOES_AIM = os.environ.get("DASH_OPEN_GOES_AIM", "http://192.168.6.134:8091/")
OPEN_WEATHER = os.environ.get("DASH_OPEN_WEATHER", "https://w.rg2.io")
OPEN_ADSB = os.environ.get("DASH_OPEN_ADSB", "https://adsb.rg2.io")
OPEN_ICECAST = os.environ.get("DASH_OPEN_ICECAST", "https://icecast.rg2.io")
# comics-display has no public NPM host yet — open the LAN UI directly.
OPEN_COMICS = os.environ.get("DASH_OPEN_COMICS", COMICS_BASE.rstrip("/") + "/")
# Meteor-M2 LRPT gallery (radio app /wxsat — the wxsat scheduler decodes off the
# GOES Pi's Nooelec). The tile reuses RADIO_BASE for its /api/wxsat/* backend.
OPEN_METEOR = os.environ.get("DASH_OPEN_METEOR", "https://radio.rg2.io/wxsat")
# Public audio mount for the radio tile's inline player (already TLS).
FM_AUDIO_URL = os.environ.get("DASH_FM_AUDIO_URL", "https://icecast.rg2.io/fm.mp3")
# Public Icecast base — the radio tile plays the live mount (FM or AM) from here.
ICECAST_PUBLIC = os.environ.get("DASH_ICECAST_PUBLIC", "https://icecast.rg2.io")
# Belchertown's generated data file — current conditions from the Davis station.
WEATHER_DATA_URL = os.environ.get("DASH_WEATHER_JSON",
                                  WEATHER_BASE.rstrip("/") + "/json/weewx_data.json")
# Continuous NOAA Weather Radio mount (HF+ 162.550) — played on the weather tile.
WX_AUDIO_URL = os.environ.get("DASH_WX_AUDIO_URL", "https://icecast.rg2.io/wx.mp3")

# GOES freshness thresholds (seconds): newer than OK is green; older than DOWN is
# red. The headline is a derived Cape-crop that regenerates slower than the raw ABI
# cadence, so OK is generous (1 h) to avoid a perpetually-amber tile.
GOES_OK_AGE = int(os.environ.get("DASH_GOES_OK_AGE", "3600"))       # 1 h
GOES_DOWN_AGE = int(os.environ.get("DASH_GOES_DOWN_AGE", "21600"))  # 6 h

# ---- Shared state ---------------------------------------------------------
_LOCK = threading.Lock()
SNAPSHOT = {"updated": 0, "domains": {}}
# Latest GOES image path (relative to GOES_BASE) for the proxy route.
_GOES_IMG = {"path": None}
# Whether comics-display currently has a comic selected (gate the thumb proxy).
_COMICS_CUR = {"id": None}
# Latest Meteor thumb path (relative to RADIO_BASE) for the proxy route.
_METEOR_IMG = {"path": None}
# Previous ADS-B sample for a message-rate delta.
_ADSB_PREV = {"messages": None, "now": None}


# ---- Fetch helpers --------------------------------------------------------
def _get_json(url):
    """GET url, parse JSON. Returns (data, None) or (None, error_str)."""
    try:
        req = urllib.request.Request(url, headers={"User-Agent": "rg2-dashboard"})
        with urllib.request.urlopen(req, timeout=TIMEOUT) as r:
            return json.loads(r.read().decode("utf-8", "replace")), None
    except Exception as e:  # noqa: BLE001 — any failure = backend unreachable
        return None, str(e)


def _head_ok(url):
    try:
        req = urllib.request.Request(url, method="HEAD",
                                     headers={"User-Agent": "rg2-dashboard"})
        with urllib.request.urlopen(req, timeout=TIMEOUT) as r:
            return 200 <= r.status < 400
    except Exception:  # noqa: BLE001
        return False


def _first(d, *keys, default=None):
    """First present, non-empty value among keys in dict d (shallow)."""
    if not isinstance(d, dict):
        return default
    for k in keys:
        v = d.get(k)
        if v not in (None, "", [], {}):
            return v
    return default


def _num(s):
    """Leading number out of a formatted string ('96.4 &#176;F' -> 96.4)."""
    if s is None:
        return None
    if isinstance(s, (int, float)):
        return float(s)
    buf = ""
    for ch in str(s):
        if ch.isdigit() or ch in ".-":
            buf += ch
        elif buf:
            break
    try:
        return float(buf)
    except ValueError:
        return None


def _ago(sec):
    if sec is None:
        return "?"
    sec = int(sec)
    if sec < 90:
        return f"{sec}s ago"
    if sec < 5400:
        return f"{sec // 60}m ago"
    if sec < 172800:
        return f"{sec // 3600}h ago"
    return f"{sec // 86400}d ago"


# ---- Per-domain pollers ---------------------------------------------------
# Each returns a tile dict: {state, headline, detail, open_url, ...extras}.
# state in {"ok","warn","down","unknown"}.

def poll_radio():
    data, err = _get_json(f"{RADIO_BASE}/api/stack-state")
    tile = {"title": "Radio", "icon": "\U0001F4FB", "open_url": OPEN_RADIO,
            "audio_url": FM_AUDIO_URL}
    if data is None:
        tile.update(state="down", headline="Offline", detail=err or "unreachable")
        return tile
    # The Radio domain is the dx-R2 FM job (+ HF+ AM). The discone's NOAA/P25/ATC
    # streams belong to the Scanner tile, so filter to fm/am bands here.
    streams = data.get("streams") or []
    rs = [s for s in streams if s.get("band") in ("fm", "am")]
    fm = next((s for s in rs if s.get("band") == "fm"), None)
    cur = (fm if (fm and fm.get("live"))
           else next((s for s in rs if s.get("live")), fm or (rs[0] if rs else None)))
    if not cur:
        tile.update(state=("ok" if data.get("icecast_ok") else "warn"),
                    headline="Online", detail="no active radio stream")
        return tile
    band = str(cur.get("band", "")).upper()
    freq = cur.get("freq")
    headline = f"{band} {freq}".strip() if freq else (band or "Radio")
    title, listeners = cur.get("title"), cur.get("listeners")
    detail = f"♪ {title}" if title else "live"
    if listeners is not None:
        detail += f"  ·  {listeners} listening"
    mount = cur.get("mount")
    tile.update(state=("ok" if cur.get("live") else "warn"),
                headline=headline, detail=detail,
                audio_url=(ICECAST_PUBLIC + mount if mount else FM_AUDIO_URL))
    return tile


# The scanner is the discone / Airspy-R2 — a SINGLE tuner coordinated by the
# r2-mode coordinator on .83. NOAA Weather Radio is the 24/7 default; P25 (MOSWIN
# trunk) and ATC airband preempt it on demand. Order = how they show as mode pills.
SCANNER_MODES = [
    {"key": "noaa", "chip": "NOAA", "name": "NOAA Weather Radio",
     "desc": "162.550 MHz · 24/7 default", "mount": "/wx.mp3"},
    {"key": "p25", "chip": "P25", "name": "P25 trunk",
     "desc": "MOSWIN trunk · scanning", "mount": "/ems.mp3"},
    {"key": "atc", "chip": "ATC", "name": "ATC airband",
     "desc": "aviation AM · on demand", "mount": "/scanner-atc.mp3"},
]


def poll_scanner():
    state, _ = _get_json(f"{SCANNER_BASE}/api/status")
    r2, r2err = _get_json(f"{SCANNER_BASE}/api/r2/state")
    tile = {"title": "Scanner", "icon": "\U0001F4E1", "open_url": OPEN_SCANNER}
    if state is None and r2 is None:
        tile.update(state="down", headline="Offline", detail=r2err or "unreachable",
                    modes=[])
        return tile
    # monitor.service backs ATC, so map unit->atc when mode isn't explicit.
    mode = str(_first(r2 or {}, "mode", "role", "r2_role", default="noaa")).lower()
    active = next((m for m in SCANNER_MODES if m["key"] == mode), None)
    headline = active["name"] if active else (mode.upper() or "Scanner")
    detail = active["desc"] if active else "monitoring"
    # A live P25 call is the one "active/now" state worth flagging.
    current = _first(state or {}, "current", "call", "talkgroup")
    call = False
    if mode == "p25" and current:
        call = True
        if isinstance(current, dict):
            tg = _first(current, "tgid", "talkgroup", "tg", "name", "desc")
            detail = f"call active · TG {tg}" if tg else "call active"
        else:
            detail = f"call active · {current}"
    modes = [{"name": m["chip"], "active": m["key"] == mode,
              "default": m["key"] == "noaa"} for m in SCANNER_MODES]
    tile.update(state=("warn" if call else "ok"), headline=headline, detail=detail,
                modes=modes,
                audio_url=(ICECAST_PUBLIC + active["mount"] if active else None))
    return tile


def poll_goes():
    data, err = _get_json(f"{GOES_BASE}/api/goes/latest")
    space, _ = _get_json(f"{GOES_BASE}/api/goes/space")
    tile = {"title": "Satellite", "icon": "\U0001F6F0️", "open_url": OPEN_GOES,
            "aim_url": OPEN_GOES_AIM}
    if not data:
        tile.update(state="down", headline="No imagery", detail=err or "archive empty")
        with _LOCK:
            _GOES_IMG["path"] = None
        return tile
    age = data.get("age_sec")
    sat = data.get("satellite", "GOES")
    sector = data.get("sector", "")
    if age is None:
        st = "unknown"
    elif age <= GOES_OK_AGE:
        st = "ok"
    elif age <= GOES_DOWN_AGE:
        st = "warn"
    else:
        st = "down"
    free = (space or {}).get("free_gb")
    detail = _ago(age)
    if free is not None:
        detail += f" · {free:.0f} GB free"
    # /api/goes/latest returns an ABSOLUTE public URL (GOES_PUBLIC_BASE); keep only
    # the path+query so the proxy can always fetch it via the internal GOES_BASE.
    img = data.get("image_url")
    img_path = None
    if img:
        sp = urlsplit(img)
        img_path = (sp.path + (f"?{sp.query}" if sp.query else "")) or img
    with _LOCK:
        _GOES_IMG["path"] = img_path
    tile.update(state=st, headline=f"{sat} · {sector}".strip(" ·"),
                detail=detail,
                image_url=("/api/proxy/goes-latest.png?ts=%d" % int(data.get("timestamp", 0))
                           if img else None))
    return tile


def _wx_condition(cur, alm):
    """Derive a sky/precip condition + emoji from Davis-station data (no cloud
    sensor, so it's a heuristic from rain rate, day/night, and sun strength)."""
    temp = _num(cur.get("outTemp_formatted") or cur.get("outTemp")) or 50
    rate = _num(cur.get("rainRate")) or 0
    if rate > 0:
        return ("Snow", "\U0001F328️") if temp <= 34 else ("Rain", "\U0001F327️")
    epoch = _num(cur.get("epoch")) or 0
    sunrise = _num(alm.get("sunrise_epoch"))
    sunset = _num(alm.get("sunset_epoch"))
    is_day = (sunrise and sunset and sunrise <= epoch <= sunset)
    if not is_day:
        return "Clear night", "\U0001F319"          # 🌙
    uv = _num(cur.get("uv")) or 0
    solar = _num(cur.get("solar_radiation")) or 0
    if uv >= 5 or solar >= 600:
        return "Sunny", "☀️"               # ☀️
    if uv >= 2 or solar >= 250:
        return "Partly cloudy", "⛅"             # ⛅
    return "Cloudy", "☁️"                  # ☁️


def poll_weather():
    wd, _ = _get_json(WEATHER_DATA_URL)
    alert, _ = _get_json(f"{WX_BASE}/api/alert")
    tile = {"title": "Weather", "icon": "\U0001F326️", "open_url": OPEN_WEATHER,
            "audio_url": WX_AUDIO_URL}

    # Active SAME/EAS alert (shown on the card + drives the top banner).
    active = (alert or {}).get("active")
    severe = False
    if active:
        tier = active.get("tier", "")
        severe = tier in ("extreme", "severe")
        tile["alert"] = {"event": active.get("event") or active.get("event_code")
                         or "Alert", "tier": tier, "areas": active.get("areas", [])}
    else:
        tile["alert"] = None

    cur = (wd or {}).get("current") or {}
    if cur:
        cond, icon = _wx_condition(cur, (wd or {}).get("almanac") or {})
        temp = _num(cur.get("outTemp_formatted") or cur.get("outTemp"))
        feels = _num(cur.get("appTemp"))
        hum = cur.get("outHumidity") or ""
        # Davis reports windcompass "N/A" when calm — show "calm" not "N/A 0 mph".
        wspd = _num(cur.get("windspeed"))
        wcomp = (cur.get("windcompass") or "").strip()
        if wspd == 0:
            wind = "calm"
        elif wcomp and wcomp.upper() != "N/A":
            wind = f"{wcomp} {cur.get('windspeed', '')}".strip()
        else:
            wind = (cur.get("windspeed") or "").strip()
        t = f"{round(temp)}°F" if temp is not None else "—"
        det = []
        if feels is not None and temp is not None and abs(feels - temp) >= 2:
            det.append(f"feels {round(feels)}°")
        if hum:
            det.append(f"{hum} RH")
        if wind:
            det.append(wind)
        # metric chips
        metrics = []
        dew = _num(cur.get("dewpoint"))
        if dew is not None:
            metrics.append({"label": "Dew", "value": f"{round(dew)}°"})
        baro = cur.get("barometer_formatted")
        if baro:
            tr = _num(cur.get("barometer_trend")) or 0
            arrow = "↑" if tr > 0.001 else ("↓" if tr < -0.001 else "→")
            metrics.append({"label": "Baro", "value": f"{baro} {arrow}"})
        uv = _num(cur.get("uv"))
        if uv is not None:
            metrics.append({"label": "UV", "value": f"{uv:g}"})
        rate = _num(cur.get("rainRate")) or 0
        if rate > 0:
            metrics.append({"label": "Rain", "value": cur.get("rainRate", "")})
        tile.update(state=("warn" if severe else "ok"), icon=icon,
                    headline=f"{t} · {cond}",
                    detail=" · ".join(det) or "current conditions",
                    metrics=metrics)
        return tile

    # No station data — fall back to up/down + alert state.
    site_up = _head_ok(f"{WEATHER_BASE}/")
    if active:
        tile.update(state=("warn" if severe else "ok"),
                    headline=f"⚠ {tile['alert']['event']}",
                    detail=f"{tile['alert']['tier']} alert active", metrics=[])
    elif site_up:
        tile.update(state="ok", headline="Station online",
                    detail="conditions unavailable", metrics=[])
    else:
        tile.update(state="down", headline="Offline", detail="unreachable", metrics=[])
    return tile


def poll_adsb():
    data, err = _get_json(f"{ADSB_BASE}/data/aircraft.json")
    tile = {"title": "ADS-B", "icon": "✈️", "open_url": OPEN_ADSB}
    if data is None:
        tile.update(state="down", headline="Offline", detail=err or "unreachable",
                    count=0)
        return tile
    craft = data.get("aircraft", []) or []
    count = len(craft)
    with_pos = sum(1 for a in craft if a.get("lat") is not None)
    # message rate from the delta between polls (messages is cumulative).
    now = data.get("now")
    msgs = data.get("messages")
    rate = None
    p = _ADSB_PREV
    if msgs is not None and now is not None and p["messages"] is not None \
            and p["now"] is not None and now > p["now"]:
        rate = (msgs - p["messages"]) / (now - p["now"])
    if msgs is not None and now is not None:
        p["messages"], p["now"] = msgs, now
    detail = f"{with_pos} with position"
    if rate is not None and rate >= 0:
        detail += f" · {rate:.0f} msg/s"
    tile.update(state="ok", headline=f"{count} aircraft", detail=detail, count=count)
    return tile


def poll_distribution():
    data, err = _get_json(f"{ICECAST_BASE}/status-json.xsl")
    tile = {"title": "Distribution", "icon": "\U0001F50A", "open_url": OPEN_ICECAST}
    if data is None:
        tile.update(state="down", headline="Offline", detail=err or "unreachable",
                    mounts=[])
        return tile
    src = ((data.get("icestats") or {}).get("source")) or []
    if isinstance(src, dict):
        src = [src]
    mounts = []
    total = 0
    for s in src:
        url = s.get("listenurl", "")
        name = "/" + url.rsplit("/", 1)[-1] if url else (s.get("server_name") or "?")
        listeners = int(s.get("listeners", 0) or 0)
        total += listeners
        mounts.append({"name": name, "listeners": listeners,
                       "title": s.get("title") or s.get("server_description") or ""})
    mounts.sort(key=lambda m: m["name"])
    tile.update(state=("ok" if mounts else "warn"),
                headline=f"{len(mounts)} mounts · {total} listeners",
                detail=", ".join(m["name"] for m in mounts[:4]) or "no live mounts",
                mounts=mounts)
    return tile


def poll_comics():
    data, err = _get_json(f"{COMICS_BASE}/api/state")
    tile = {"title": "Comics", "icon": "\U0001F5BC️", "open_url": OPEN_COMICS}
    if data is None:
        tile.update(state="down", headline="Offline", detail=err or "unreachable")
        with _LOCK:
            _COMICS_CUR["id"] = None
        return tile
    srcs = data.get("sources", []) or []
    enabled = [s for s in srcs if s.get("enabled")]
    ready = [s for s in enabled if (s.get("status") or {}).get("has_frame")]
    errored = [s for s in enabled if not (s.get("status") or {}).get("ok")]
    cur = data.get("current")
    cur_name = next((s.get("name") for s in srcs if s.get("id") == cur), cur)
    # A ready enabled source means the panel has something to show → ok; some
    # enabled but none ready yet → warn; nothing enabled → warn.
    if enabled and ready:
        st = "warn" if errored else "ok"
    else:
        st = "warn"
    detail = f"{len(ready)}/{len(enabled)} sources ready"
    if errored:
        detail += f" · {len(errored)} erroring (last good shown)"
    with _LOCK:
        _COMICS_CUR["id"] = cur if cur else None
    tile.update(state=st, headline=(f"Showing: {cur_name}" if cur_name else "No comic ready"),
                detail=detail,
                image_url=("/api/proxy/comics-current.png?ts=%d" % int(time.time() // 60)
                           if cur else None))
    return tile


def poll_meteor():
    """Meteor-M2 LRPT tile: next passes (upcoming) + last decode (past).

    Backend is the radio app's /api/wxsat/* (the rack wxsat scheduler decodes off
    the GOES Pi's Nooelec). Reuses RADIO_BASE — no separate base needed.
    """
    tile = {"title": "Meteor", "icon": "☄️", "open_url": OPEN_METEOR,
            "upcoming": []}
    status, err = _get_json(f"{RADIO_BASE}/api/wxsat/status")
    if status is None:
        tile.update(state="down", headline="Offline", detail=err or "unreachable")
        with _LOCK:
            _METEOR_IMG["path"] = None
        return tile
    passes, _ = _get_json(f"{RADIO_BASE}/api/wxsat/passes")
    caps, _ = _get_json(f"{RADIO_BASE}/api/wxsat/captures")
    now = time.time()

    plist = passes.get("passes", []) if isinstance(passes, dict) else (passes or [])
    for p in plist[:3]:
        aos = p.get("aos_unix")
        tile["upcoming"].append({
            "sat": p.get("satellite", "METEOR-M2"),
            "elev": round(_num(p.get("max_elev")) or 0),
            "in_min": (max(0, round((aos - now) / 60)) if aos else None),
        })

    clist = caps.get("captures", []) if isinstance(caps, dict) else (caps or [])
    last_img = next((c for c in clist if c.get("image") or c.get("thumb")), None)
    if last_img:
        rel = last_img.get("thumb") or last_img.get("image")
        with _LOCK:
            _METEOR_IMG["path"] = f"/api/wxsat/image/{rel}"
        tile["image_url"] = "/api/proxy/meteor-latest.png?ts=%d" % int(last_img.get("created", 0))
    else:
        with _LOCK:
            _METEOR_IMG["path"] = None

    state_word = (status.get("state") or "idle").lower()
    # capturing/decoding = actively working (green); scheduled/idle = fine (green);
    # anything unexpected = warn.
    tile["state"] = "ok" if state_word in ("capturing", "decoding", "scheduled", "idle") else "warn"
    cap = status.get("capturing_pass") or {}
    nxt = status.get("next_pass") or (plist[0] if plist else {})
    if cap:
        tile["headline"] = f"Capturing {cap.get('satellite', 'METEOR-M2')}"
    elif nxt:
        mins = tile["upcoming"][0]["in_min"] if tile["upcoming"] else None
        when = f"in {mins}m" if mins is not None else ""
        tile["headline"] = f"{nxt.get('satellite', 'METEOR-M2')} {round(_num(nxt.get('max_elev')) or 0)}° {when}".strip()
    else:
        tile["headline"] = "No passes scheduled"
    n_img = sum(1 for c in clist if c.get("image"))
    tile["detail"] = f"{len(tile['upcoming'])} upcoming · {n_img} decoded"
    return tile


POLLERS = {
    "radio": poll_radio,
    "scanner": poll_scanner,
    "satellite": poll_goes,
    "meteor": poll_meteor,
    "weather": poll_weather,
    "adsb": poll_adsb,
    "comics": poll_comics,
    "distribution": poll_distribution,
}


def poll_once():
    domains = {}
    for key, fn in POLLERS.items():
        try:
            domains[key] = fn()
        except Exception as e:  # noqa: BLE001 — never let one tile break the snapshot
            domains[key] = {"title": key.title(), "state": "unknown",
                            "headline": "Error", "detail": str(e)}
    with _LOCK:
        SNAPSHOT["domains"] = domains
        SNAPSHOT["updated"] = int(time.time())


def poller_loop():
    while True:
        poll_once()
        time.sleep(POLL_INTERVAL)


# ---- HTTP handler ---------------------------------------------------------
class Handler(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def _send(self, code, body, ctype, extra=None):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Cache-Control", "no-store")
        for k, v in (extra or {}).items():
            self.send_header(k, v)
        self.end_headers()
        self.wfile.write(body)

    def _json(self, code, obj):
        self._send(code, json.dumps(obj).encode(), "application/json")

    def do_GET(self):
        path = self.path.split("?", 1)[0]
        if path in ("/", "/index.html"):
            self._send(200, PAGE.replace("__TITLE__", SITE_TITLE).encode(),
                       "text/html; charset=utf-8")
        elif path == "/api/dashboard":
            with _LOCK:
                self._json(200, dict(SNAPSHOT))
        elif path == "/api/proxy/goes-latest.png":
            self._proxy_goes()
        elif path == "/api/proxy/comics-current.png":
            self._proxy_comics()
        elif path == "/api/proxy/meteor-latest.png":
            self._proxy_meteor()
        elif path == "/healthz":
            self._json(200, {"ok": True})
        else:
            self._json(404, {"error": "not found"})

    def _proxy_goes(self):
        with _LOCK:
            path = _GOES_IMG["path"]
        if not path:
            self._json(404, {"error": "no image"})
            return
        # path is a normalized path+query; always fetch via the internal GOES base
        # (no open redirect — we never honor a caller-supplied host).
        if not path.startswith("/"):
            self._json(400, {"error": "bad path"})
            return
        url = GOES_BASE + path
        try:
            req = urllib.request.Request(url, headers={"User-Agent": "rg2-dashboard"})
            with urllib.request.urlopen(req, timeout=TIMEOUT + 2) as r:
                ctype = r.headers.get("Content-Type", "image/png")
                self._send(200, r.read(), ctype,
                           extra={"Cache-Control": "public, max-age=60"})
        except Exception as e:  # noqa: BLE001
            self._json(502, {"error": str(e)})

    def _proxy_comics(self):
        # Serve the panel's current comic as a same-origin thumbnail (the tile is
        # HTTPS, comics-display is plain HTTP). /current.png doesn't advance the
        # rotation, so polling this never steals a comic from the device.
        with _LOCK:
            cur = _COMICS_CUR["id"]
        if not cur:
            self._json(404, {"error": "no comic"})
            return
        try:
            req = urllib.request.Request(COMICS_BASE.rstrip("/") + "/current.png",
                                         headers={"User-Agent": "rg2-dashboard"})
            with urllib.request.urlopen(req, timeout=TIMEOUT + 2) as r:
                ctype = r.headers.get("Content-Type", "image/png")
                self._send(200, r.read(), ctype,
                           extra={"Cache-Control": "public, max-age=60"})
        except Exception as e:  # noqa: BLE001
            self._json(502, {"error": str(e)})

    def _proxy_meteor(self):
        with _LOCK:
            path = _METEOR_IMG["path"]
        if not path:
            self._json(404, {"error": "no image"})
            return
        # path is a fixed /api/wxsat/image/<rel> route; fetch via the internal
        # RADIO_BASE only (never a caller-supplied host).
        if not path.startswith("/"):
            self._json(400, {"error": "bad path"})
            return
        url = RADIO_BASE + path
        try:
            req = urllib.request.Request(url, headers={"User-Agent": "rg2-dashboard"})
            with urllib.request.urlopen(req, timeout=TIMEOUT + 2) as r:
                ctype = r.headers.get("Content-Type", "image/png")
                self._send(200, r.read(), ctype,
                           extra={"Cache-Control": "public, max-age=60"})
        except Exception as e:  # noqa: BLE001
            self._json(502, {"error": str(e)})


# ---- Page (Material Design 3, dark). Vanilla CSS + JS, no build step. ------
PAGE = r"""<!doctype html>
<html lang="en"><head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="color-scheme" content="dark">
<title>__TITLE__</title>
<link rel="preconnect" href="https://fonts.googleapis.com">
<link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
<link href="https://fonts.googleapis.com/css2?family=Roboto:wght@400;500;700&display=swap" rel="stylesheet">
<style>
:root{
  /* MD3 dark scheme, tuned to the platform's existing palette (accent #4ea1ff). */
  --bg:#0a0e16; --surface:#0e1622; --sc:#131b28; --sc-high:#1a2433; --sc-hi2:#202c3e;
  --outline:#26344a; --outline-v:#1c2839;
  --on:#e6edf5; --on-v:#9babc4; --dim:#7b8aaa;
  --primary:#7fc0ff; --on-primary:#06223c; --p-container:#1b3a5c; --on-p-container:#cfe6ff;
  --green:#5ce08a; --red:#ff6a6a; --amber:#ffc04a; --grey:#5d6b82;
  --r-card:20px; --r-pill:999px; --r-chip:10px;
  --shadow:0 1px 2px rgba(0,0,0,.5),0 2px 8px rgba(0,0,0,.35);
}
*{box-sizing:border-box}
html,body{margin:0}
body{
  background:radial-gradient(1200px 600px at 50% -200px,#15263e 0%,var(--bg) 55%) fixed;
  color:var(--on);
  font:400 15px/1.5 "Roboto",system-ui,-apple-system,"Segoe UI",sans-serif;
  min-height:100vh;-webkit-font-smoothing:antialiased;
}
/* Top app bar */
.appbar{
  position:sticky;top:0;z-index:20;
  display:flex;align-items:center;gap:14px;
  padding:16px clamp(16px,4vw,40px);
  background:rgba(10,14,22,.78);backdrop-filter:blur(14px);
  border-bottom:1px solid var(--outline-v);
}
.appbar .logo{
  width:42px;height:42px;border-radius:13px;flex:0 0 auto;
  display:grid;place-items:center;font-size:22px;
  background:linear-gradient(135deg,var(--p-container),#0f2840);
  border:1px solid var(--outline);
}
.appbar h1{font-size:1.15rem;font-weight:700;margin:0;letter-spacing:.2px}
.appbar .sub{font-size:.8rem;color:var(--on-v);margin-top:1px}
.appbar .health{margin-left:auto;display:flex;align-items:center;gap:10px;
  font-size:.82rem;color:var(--on-v)}
.appbar .health .summary{display:flex;gap:6px}
.appbar .updated{font-variant-numeric:tabular-nums;font-size:.74rem;color:var(--dim)}
/* EAS banner */
.eas{margin:14px clamp(16px,4vw,40px) 0;padding:14px 18px;border-radius:16px;
  display:flex;align-items:center;gap:12px;font-weight:500;
  background:linear-gradient(135deg,#4a1414,#2a0d0d);
  border:1px solid #6a2222;color:#ffd9d9;box-shadow:var(--shadow)}
.eas .ico{font-size:1.4rem}
.eas.warn{background:linear-gradient(135deg,#4a3410,#2a1f08);border-color:#6a4f1f;color:#ffe9c2}
.eas[hidden]{display:none}
/* Grid */
.grid{
  display:grid;gap:18px;padding:18px clamp(16px,4vw,40px) 48px;
  grid-template-columns:repeat(auto-fill,minmax(320px,1fr));max-width:1500px;margin:0 auto;
}
.card{
  background:linear-gradient(180deg,var(--sc-high),var(--sc));
  border:1px solid var(--outline-v);border-radius:var(--r-card);
  padding:18px 18px 16px;box-shadow:var(--shadow);
  display:flex;flex-direction:column;gap:13px;position:relative;overflow:hidden;
  transition:border-color .2s,transform .2s,box-shadow .2s;
}
.card:hover{border-color:var(--outline);transform:translateY(-2px);
  box-shadow:0 4px 14px rgba(0,0,0,.5)}
.card .accent{position:absolute;inset:0 0 auto 0;height:3px;
  background:linear-gradient(90deg,var(--primary),transparent 70%);opacity:.5}
.chead{display:flex;align-items:center;gap:12px}
.chead .ic{width:44px;height:44px;flex:0 0 auto;border-radius:14px;display:grid;
  place-items:center;font-size:22px;background:var(--p-container);
  border:1px solid var(--outline)}
.chead .t{flex:1;min-width:0}
.chead .title{font-weight:700;font-size:1.02rem}
.chead .headline{font-size:.85rem;color:var(--on-v);margin-top:1px;
  white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.dot{width:11px;height:11px;border-radius:50%;flex:0 0 auto;background:var(--grey);
  box-shadow:0 0 0 4px rgba(255,255,255,.03)}
.dot.ok{background:var(--green);box-shadow:0 0 10px var(--green)}
.dot.warn{background:var(--amber);box-shadow:0 0 10px var(--amber)}
.dot.down{background:var(--red);box-shadow:0 0 10px var(--red)}
.dot.unknown{background:var(--grey)}
.detail{font-size:.88rem;color:var(--on);min-height:1.2em}
.detail .muted{color:var(--on-v)}
/* preview area */
.preview{display:flex;flex-direction:column;gap:10px}
.thumb{width:100%;aspect-ratio:16/10;object-fit:cover;border-radius:12px;
  background:#0a121d;border:1px solid var(--outline-v)}
.big{font-size:2.4rem;font-weight:700;line-height:1;letter-spacing:-1px}
.big .u{font-size:.95rem;font-weight:500;color:var(--on-v);margin-left:6px}
audio{width:100%;height:34px;border-radius:var(--r-pill);filter:saturate(.9)}
.chips{display:flex;flex-wrap:wrap;gap:7px}
.chip{display:inline-flex;align-items:center;gap:6px;padding:5px 10px;
  border-radius:var(--r-chip);background:var(--sc-hi2);border:1px solid var(--outline-v);
  font-size:.78rem;color:var(--on-v);font-variant-numeric:tabular-nums}
.chip b{color:var(--on);font-weight:600}
.chip .ld{width:7px;height:7px;border-radius:50%;background:var(--green)}
.chip.idle .ld{background:var(--grey)}
/* scanner mode pills */
.chip.mode{padding:6px 11px}
.chip.mode.active{background:var(--p-container);border-color:var(--primary);
  color:var(--on-p-container);font-weight:600;box-shadow:0 0 0 1px var(--primary) inset}
.chip .def{font-size:.62rem;text-transform:uppercase;letter-spacing:.5px;
  color:var(--dim);margin-left:5px}
.chip.mode.active .def{color:var(--primary)}
.chip .ck{color:var(--on-v)}
/* weather */
.wxalert{padding:8px 12px;border-radius:10px;font-size:.82rem;
  background:linear-gradient(135deg,#4a3410,#2a1f08);border:1px solid #6a4f1f;color:#ffe9c2}
.wxalert.sev{background:linear-gradient(135deg,#4a1414,#2a0d0d);
  border-color:#6a2222;color:#ffd9d9}
.nwr{font-size:.72rem;color:var(--on-v);font-weight:600;letter-spacing:.3px;margin-top:2px}
/* open button (MD3 filled-tonal) */
.foot{margin-top:auto;display:flex;align-items:center;gap:10px;padding-top:4px}
.open{margin-left:auto;display:inline-flex;align-items:center;gap:7px;
  text-decoration:none;font-weight:600;font-size:.85rem;
  padding:9px 16px;border-radius:var(--r-pill);
  background:var(--p-container);color:var(--on-p-container);
  border:1px solid var(--outline);transition:background .15s,transform .1s}
.open:hover{background:var(--sc-hi2)}
.open:active{transform:scale(.97)}
.acts{margin-left:auto;display:flex;align-items:center;gap:8px}
.acts .open{margin-left:0}
.open.alt{background:transparent;color:var(--on-v);border-color:var(--outline)}
.open.alt:hover{background:var(--sc-hi2);color:var(--on)}
.open .ar{font-size:1.05rem;line-height:1}
.state-label{font-size:.72rem;text-transform:uppercase;letter-spacing:.6px;
  color:var(--on-v);font-weight:600}
footer{text-align:center;color:var(--dim);font-size:.76rem;padding:0 0 40px}
@media(max-width:560px){.appbar .sub{display:none}.big{font-size:2rem}}
</style></head>
<body>
<header class="appbar">
  <div class="logo">📡</div>
  <div>
    <h1>__TITLE__</h1>
    <div class="sub">SDR homelab — acquisition, DSP &amp; distribution</div>
  </div>
  <div class="health">
    <div class="summary" id="summary"></div>
    <div class="updated" id="updated">connecting…</div>
  </div>
</header>
<div class="eas" id="eas" hidden><span class="ico">⚠️</span><span id="eastxt"></span></div>
<main class="grid" id="grid"></main>
<footer>Polling every <span id="ivl"></span>s · <a href="#" onclick="location.reload();return false" style="color:var(--primary)">refresh</a></footer>
<script>
"use strict";
var $=function(id){return document.getElementById(id)};
var STATES={ok:"online",warn:"active",down:"offline",unknown:"—"};
var ORDER=["radio","scanner","satellite","meteor","weather","adsb","comics","distribution"];

function esc(s){return String(s==null?"":s).replace(/[&<>"]/g,function(c){
  return {"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;"}[c]})}

function preview(key,d){
  if(key==="radio"&&d.audio_url&&d.state!=="down")
    return '<div class="preview"><audio controls preload="none" src="'+esc(d.audio_url)+'"></audio></div>';
  if(key==="satellite"&&d.image_url)
    return '<div class="preview"><img class="thumb" alt="latest GOES image" src="'+esc(d.image_url)+'" onerror="this.style.display=\'none\'"></div>';
  if(key==="comics"&&d.image_url)
    return '<div class="preview"><img class="thumb" alt="current comic" src="'+esc(d.image_url)+'" onerror="this.style.display=\'none\'"></div>';
  if(key==="meteor"){
    var mp="";
    if(d.image_url)
      mp+='<img class="thumb" alt="latest Meteor decode" src="'+esc(d.image_url)+'" onerror="this.style.display=\'none\'">';
    if(d.upcoming&&d.upcoming.length)
      mp+='<div class="chips">'+d.upcoming.map(function(u){
        return '<span class="chip"><span class="ld"></span>'+esc(u.sat)+
          ' <b>'+(u.elev||0)+'°</b>'+(u.in_min!=null?' <span class="ck">in '+u.in_min+'m</span>':'')+
          '</span>'}).join("");
    return mp?'<div class="preview">'+mp+'</div>':"";
  }
  if(key==="scanner"&&d.modes&&d.modes.length){
    var pills=d.modes.map(function(m){
      return '<span class="chip mode'+(m.active?" active":"")+'">'+esc(m.name)+
        (m.default?'<span class="def">default</span>':'')+'</span>'}).join("");
    var au=d.audio_url?'<audio controls preload="none" src="'+esc(d.audio_url)+'"></audio>':'';
    return '<div class="preview"><div class="chips">'+pills+'</div>'+au+'</div>';
  }
  if(key==="adsb")
    return '<div class="preview"><div class="big">'+(d.count||0)+'<span class="u">aircraft tracked</span></div></div>';
  if(key==="distribution"&&d.mounts&&d.mounts.length){
    var c=d.mounts.map(function(m){
      return '<span class="chip '+(m.listeners>0?"":"idle")+'"><span class="ld"></span>'+
        esc(m.name)+' <b>'+m.listeners+'</b></span>'}).join("");
    return '<div class="preview"><div class="chips">'+c+'</div></div>';
  }
  if(key==="weather"){
    var parts="";
    if(d.alert){
      var sev=(d.alert.tier==="extreme"||d.alert.tier==="severe");
      parts+='<div class="wxalert'+(sev?" sev":"")+'">⚠️ <b>'+esc(d.alert.event)+
        '</b> · '+esc(d.alert.tier)+(d.alert.areas&&d.alert.areas.length?
        ' ('+esc(d.alert.areas.join(", "))+')':'')+'</div>';
    }
    if(d.metrics&&d.metrics.length)
      parts+='<div class="chips">'+d.metrics.map(function(m){
        return '<span class="chip"><span class="ck">'+esc(m.label)+'</span> <b>'+
          esc(m.value)+'</b></span>'}).join("")+'</div>';
    if(d.audio_url)
      parts+='<div class="nwr">📻 NOAA Weather Radio · 162.550</div>'+
        '<audio controls preload="none" src="'+esc(d.audio_url)+'"></audio>';
    return parts?'<div class="preview">'+parts+'</div>':"";
  }
  return "";
}

function card(key,d){
  var st=d.state||"unknown";
  return '<article class="card"><div class="accent"></div>'+
    '<div class="chead"><div class="ic">'+esc(d.icon||"")+'</div>'+
      '<div class="t"><div class="title">'+esc(d.title||key)+'</div>'+
        '<div class="headline">'+esc(d.headline||"")+'</div></div>'+
      '<div class="dot '+st+'" title="'+STATES[st]+'"></div></div>'+
    '<div class="detail">'+esc(d.detail||"")+'</div>'+
    preview(key,d)+
    '<div class="foot"><span class="state-label">'+STATES[st]+'</span>'+
      '<div class="acts">'+
        (d.aim_url?'<a class="open alt" href="'+esc(d.aim_url)+'" target="_blank" rel="noopener" title="Dish aiming + signal peaking">Aim</a>':'')+
        '<a class="open" href="'+esc(d.open_url||"#")+'" target="_blank" rel="noopener">Open <span class="ar">→</span></a>'+
      '</div></div>'+
  '</article>';
}

function render(s){
  var dom=s.domains||{};
  // EAS banner
  var w=dom.weather||{}, eas=$("eas");
  if(w.alert){eas.hidden=false;eas.className="eas "+(w.alert.tier==="extreme"||w.alert.tier==="severe"?"":"warn");
    $("eastxt").textContent=w.alert.event+" — "+(w.alert.tier||"")+" alert active"+
      (w.alert.areas&&w.alert.areas.length?" ("+w.alert.areas.join(", ")+")":"");}
  else{eas.hidden=true;}
  // cards
  var html="",sum="";
  ORDER.forEach(function(k){if(dom[k]){html+=card(k,dom[k]);
    sum+='<span class="dot '+(dom[k].state||"unknown")+'" title="'+esc(dom[k].title)+'"></span>';}});
  $("grid").innerHTML=html;$("summary").innerHTML=sum;
  if(s.updated){var ago=Math.max(0,Math.round(Date.now()/1000-s.updated));
    $("updated").textContent="updated "+(ago<2?"just now":ago+"s ago");}
}

function poll(){fetch("/api/dashboard",{cache:"no-store"})
  .then(function(r){return r.json()}).then(render)
  .catch(function(){$("updated").textContent="reconnecting…"})}
$("ivl").textContent="10";
poll();setInterval(poll,10000);
</script>
</body></html>"""


def main():
    poll_once()  # warm the snapshot before serving
    threading.Thread(target=poller_loop, daemon=True, name="poller").start()
    print(f"dashboard on :{PORT} title={SITE_TITLE!r} interval={POLL_INTERVAL}s",
          flush=True)
    ThreadingHTTPServer(("0.0.0.0", PORT), Handler).serve_forever()


if __name__ == "__main__":
    main()
