#!/usr/bin/env python3
"""comics.py — rotating classic-comics server for the Seeed reTerminal E1002.

The E1002 is a 7.3" E Ink Spectra 6 (6-colour) 800x480 ePaper panel on an
ESP32-S3. The device is dumb on purpose: it wakes from deep sleep every few
hours, does ONE HTTP GET for a pre-rendered image, draws it, and sleeps again
(see firmware/reterminal-e1002-comics.yaml). ALL the work lives here:

  * scrape a rotating pool of comic sources (XKCD, GoComics strips such as
    Calvin and Hobbes, The Far Side daily dose, or any page via its og:image),
  * fit each to 800x480 (letterboxed on paper-white),
  * dither to the panel's 6-colour palette (black/white/red/green/blue/yellow),
  * serve the current pick at a stable URL, advancing on /next.png.

A small web UI at / lets you add / drop / enable / disable sources live — no
redeploy. Sources persist in DATA_DIR/sources.json (NOT provisioner-managed, so
UI edits survive a re-apply); rendered frames cache in DATA_DIR/pool.

Stdlib + Pillow only (mirrors dashboard.py / goes_gallery.py). Config via env
(see /etc/comics-display/comics.env). Every scrape is wrapped + timeout-bounded;
a failing source degrades to its last good frame and never blocks rotation.

Legal note: this is a single personal device pulling each source's own
current strip for private display — no redistribution. XKCD is CC-licensed with
a real JSON API; the scraped strips (Calvin and Hobbes, The Far Side, …) have no
official feed, so those handlers are best-effort against the public pages.
"""
import io
import json
import os
import random
import threading
import time
import urllib.request
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlsplit, urljoin

from PIL import Image

try:
    from zoneinfo import ZoneInfo
except Exception:  # pragma: no cover — py<3.9 / no tzdata
    ZoneInfo = None

# ---- Config ---------------------------------------------------------------
PORT = int(os.environ.get("COMICS_PORT", "8080"))
DATA_DIR = os.environ.get("COMICS_DATA_DIR", "/var/lib/comics-display")
# How long a fetched frame is considered fresh before the scraper re-pulls it.
# Comics update at most daily, so 6 h keeps them current without hammering.
REFRESH_SEC = int(os.environ.get("COMICS_REFRESH_SEC", "21600"))  # 6 h
# Optional wall-clock auto-advance for the web preview. 0 = device-driven only
# (every /next.png from the panel advances; nothing rotates on its own).
AUTO_ADVANCE_SEC = int(os.environ.get("COMICS_AUTO_ADVANCE_SEC", "0"))
TIMEOUT = float(os.environ.get("COMICS_TIMEOUT", "12"))
LOCAL_TZ = os.environ.get("COMICS_TZ", "America/Chicago")
# Panel geometry — the E1002 is 800x480 landscape.
W = int(os.environ.get("COMICS_WIDTH", "800"))
H = int(os.environ.get("COMICS_HEIGHT", "480"))
# Paper-white letterbox behind the strip; comics rarely match 5:3.
BG = (255, 255, 255)
# A browser-ish UA — several comic hosts 403 the stdlib default.
UA = os.environ.get(
    "COMICS_UA",
    "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 "
    "(KHTML, like Gecko) Chrome/124.0 Safari/537.36",
)

POOL_DIR = os.path.join(DATA_DIR, "pool")
SOURCES_PATH = os.path.join(DATA_DIR, "sources.json")
STATE_PATH = os.path.join(DATA_DIR, "state.json")

# The E Ink Spectra 6 primaries. The panel itself is not pure sRGB (its red is
# ~ (180,40,30)), but we hand the firmware clean primaries and let the display
# driver map them — dithering to pure points gives the most predictable result.
E6_PALETTE = [
    (0, 0, 0),        # black
    (255, 255, 255),  # white
    (255, 0, 0),      # red
    (0, 255, 0),      # green
    (0, 0, 255),      # blue
    (255, 255, 0),    # yellow
]
MONO_PALETTE = [(0, 0, 0), (255, 255, 255)]

# Seed sources on first run only (afterwards the UI owns sources.json).
DEFAULT_SOURCES = [
    {"id": "xkcd", "name": "xkcd", "type": "xkcd", "mode": "random",
     "palette": "auto", "enabled": True},
    {"id": "calvinandhobbes", "name": "Calvin and Hobbes", "type": "gocomics",
     "slug": "calvinandhobbes", "palette": "auto", "enabled": True},
    {"id": "farside", "name": "The Far Side", "type": "farside",
     "palette": "mono", "enabled": True},
]

# ---- State ----------------------------------------------------------------
_LOCK = threading.RLock()
_SOURCES = []          # list of source dicts
_META = {}             # id -> {fetched_at, ok, error, palette_used, src_url}
_STATE = {"current": None, "order_pos": -1, "advanced_at": 0}


# ---- Small helpers --------------------------------------------------------
def _now():
    return int(time.time())


def _local_now():
    if ZoneInfo:
        try:
            return datetime.now(ZoneInfo(LOCAL_TZ))
        except Exception:  # noqa: BLE001
            pass
    return datetime.now(timezone.utc)


def _http_get(url, as_json=False):
    """GET url. Returns bytes (or parsed JSON). Raises on failure."""
    req = urllib.request.Request(url, headers={"User-Agent": UA,
                                               "Accept": "*/*"})
    with urllib.request.urlopen(req, timeout=TIMEOUT) as r:
        data = r.read()
    if as_json:
        return json.loads(data.decode("utf-8", "replace"))
    return data


def _meta_re(html, prop):
    """Pull a <meta property/name="prop" content="..."> value out of HTML.

    Tiny hand-rolled matcher (no bs4 dep) tolerant of attribute order and of
    single/double quotes. Returns the content or None.
    """
    import re
    for pat in (
        r'<meta[^>]+(?:property|name)=["\']%s["\'][^>]+content=["\']([^"\']+)["\']' % re.escape(prop),
        r'<meta[^>]+content=["\']([^"\']+)["\'][^>]+(?:property|name)=["\']%s["\']' % re.escape(prop),
    ):
        m = re.search(pat, html, re.IGNORECASE)
        if m:
            return m.group(1)
    return None


def _all_imgs(html, base):
    """All <img src>/data-srcs in HTML, resolved absolute. Order-preserving."""
    import re
    out, seen = [], set()
    for m in re.finditer(r'<img[^>]+?(?:data-src|src)=["\']([^"\']+)["\']',
                         html, re.IGNORECASE):
        u = urljoin(base, m.group(1))
        if u not in seen:
            seen.add(u)
            out.append(u)
    return out


# ---- Source fetchers ------------------------------------------------------
# Each returns (image_bytes, source_url). Raises on failure. Best-effort: the
# scraped hosts have no API contract, so parsing is defensive with og:image as
# the near-universal fallback.
def _fetch_xkcd(src):
    latest = _http_get("https://xkcd.com/info.0.json", as_json=True)
    num = latest.get("num", 1)
    if src.get("mode", "random") == "random" and num > 1:
        n = random.randint(1, num)
        info = _http_get("https://xkcd.com/%d/info.0.json" % n, as_json=True)
    else:
        info = latest
    img_url = info["img"]
    return _http_get(img_url), img_url


def _fetch_gocomics(src):
    slug = src["slug"]
    d = _local_now()
    # Try today then walk back a few days — the current strip may not be posted
    # yet in our timezone, and GoComics 404s a date with no strip.
    last_err = None
    for back in range(0, 5):
        day = d.fromordinal(d.toordinal() - back)
        url = "https://www.gocomics.com/%s/%04d/%02d/%02d" % (
            slug, day.year, day.month, day.day)
        try:
            html = _http_get(url).decode("utf-8", "replace")
        except Exception as e:  # noqa: BLE001
            last_err = e
            continue
        img = _meta_re(html, "og:image")
        if img and "gocomics" in img.lower():
            return _http_get(img), img
        last_err = RuntimeError("no strip image on %s" % url)
    raise last_err or RuntimeError("gocomics fetch failed")


def _fetch_farside(src):
    # thefarside.com rotates a "Daily Dose" of cartoons on the homepage. Grab a
    # cartoon image (their CDN path contains /assets/ or /cartoons/); fall back
    # to og:image. Pick randomly so repeated pulls vary within the day.
    html = _http_get("https://www.thefarside.com/").decode("utf-8", "replace")
    imgs = [u for u in _all_imgs(html, "https://www.thefarside.com/")
            if any(k in u.lower() for k in ("/cartoon", "/assets/", "tfs/"))
            and u.lower().split("?")[0].endswith((".jpg", ".jpeg", ".png", ".gif"))]
    if imgs:
        url = random.choice(imgs)
        return _http_get(url), url
    og = _meta_re(html, "og:image")
    if og:
        return _http_get(og), og
    raise RuntimeError("no far side cartoon found on homepage")


def _fetch_ogimage(src):
    """Generic: fetch a page, use its og:image. Covers most comic sites."""
    url = src["url"]
    html = _http_get(url).decode("utf-8", "replace")
    img = _meta_re(html, "og:image") or _meta_re(html, "twitter:image")
    if not img:
        raise RuntimeError("no og:image on %s" % url)
    img = urljoin(url, img)
    return _http_get(img), img


def _fetch_image(src):
    """Generic: the URL points straight at an image file."""
    url = src["url"]
    return _http_get(url), url


FETCHERS = {
    "xkcd": _fetch_xkcd,
    "gocomics": _fetch_gocomics,
    "farside": _fetch_farside,
    "ogimage": _fetch_ogimage,
    "image": _fetch_image,
}


# ---- Rendering ------------------------------------------------------------
def _palette_image(colors):
    pal = Image.new("P", (1, 1))
    flat = []
    for c in colors:
        flat += list(c)
    flat += [0] * (768 - len(flat))
    pal.putpalette(flat)
    return pal


def _mean_saturation(img):
    """Rough mean saturation (0..255) of a downsampled RGB image."""
    small = img.convert("RGB").resize((64, 64))
    s = small.convert("HSV").getchannel("S")
    px = list(s.getdata())
    return sum(px) / len(px) if px else 0


def render(raw_bytes, palette_mode="auto"):
    """Raw image bytes -> 800x480 PNG + BMP dithered to the panel palette.

    palette_mode: 'color' (full 6), 'mono' (black/white — best for line-art
    dailies like The Far Side, avoids JPEG-speckle colour), or 'auto' (mono when
    the source is nearly greyscale, else colour).
    """
    src = Image.open(io.BytesIO(raw_bytes))
    # Flatten transparency onto paper white.
    if src.mode in ("RGBA", "LA", "P"):
        src = src.convert("RGBA")
        flat = Image.new("RGBA", src.size, (255, 255, 255, 255))
        flat.alpha_composite(src)
        src = flat.convert("RGB")
    else:
        src = src.convert("RGB")

    mode = palette_mode
    if mode == "auto":
        mode = "mono" if _mean_saturation(src) < 18 else "color"
    palette = MONO_PALETTE if mode == "mono" else E6_PALETTE

    # Fit within the panel, letterbox the rest on white.
    canvas = Image.new("RGB", (W, H), BG)
    fitted = src.copy()
    fitted.thumbnail((W, H), Image.LANCZOS)
    canvas.paste(fitted, ((W - fitted.width) // 2, (H - fitted.height) // 2))

    dithered = canvas.quantize(
        palette=_palette_image(palette), dither=Image.Dither.FLOYDSTEINBERG
    ).convert("RGB")

    png = io.BytesIO()
    dithered.save(png, format="PNG")
    bmp = io.BytesIO()
    dithered.save(bmp, format="BMP")
    return png.getvalue(), bmp.getvalue(), mode


# ---- Pool / persistence ---------------------------------------------------
def _load_json(path, default):
    try:
        with open(path) as f:
            return json.load(f)
    except Exception:  # noqa: BLE001
        return default


def _atomic_write(path, data, binary=False):
    tmp = path + ".tmp"
    flags = "wb" if binary else "w"
    with open(tmp, flags) as f:
        f.write(data)
    os.replace(tmp, path)


def _save_sources():
    _atomic_write(SOURCES_PATH, json.dumps({"sources": _SOURCES}, indent=2))


def _save_state():
    _atomic_write(STATE_PATH, json.dumps(_STATE))


def _pool_paths(sid):
    return (os.path.join(POOL_DIR, sid + ".png"),
            os.path.join(POOL_DIR, sid + ".bmp"))


def _has_frame(sid):
    return os.path.exists(_pool_paths(sid)[0])


def fetch_source(src, force=False):
    """Scrape + render one source into the pool. Returns True on success."""
    sid = src["id"]
    with _LOCK:
        m = _META.get(sid, {})
        fresh = (not force and m.get("ok") and _has_frame(sid)
                 and _now() - m.get("fetched_at", 0) < REFRESH_SEC)
    if fresh:
        return True
    fetcher = FETCHERS.get(src["type"])
    if not fetcher:
        with _LOCK:
            _META[sid] = {"ok": False, "error": "unknown type %r" % src["type"],
                          "fetched_at": _now()}
        return False
    try:
        raw, url = fetcher(src)
        png, bmp, mode_used = render(raw, src.get("palette", "auto"))
        ppath, bpath = _pool_paths(sid)
        _atomic_write(ppath, png, binary=True)
        _atomic_write(bpath, bmp, binary=True)
        with _LOCK:
            _META[sid] = {"ok": True, "error": None, "fetched_at": _now(),
                          "palette_used": mode_used, "src_url": url}
        return True
    except Exception as e:  # noqa: BLE001 — any scrape/render failure
        with _LOCK:
            _META[sid] = {"ok": False, "error": str(e)[:300],
                          "fetched_at": _now(),
                          "had_frame": _has_frame(sid)}
        return False


def _enabled_ordered():
    return [s for s in _SOURCES if s.get("enabled")]


def _ready_ids():
    """Enabled sources that currently have a rendered frame, in order."""
    return [s["id"] for s in _enabled_ordered() if _has_frame(s["id"])]


def advance():
    """Move the pointer to the next ready source (round-robin). Returns id."""
    with _LOCK:
        ready = _ready_ids()
        if not ready:
            return None
        cur = _STATE.get("current")
        if cur in ready:
            nxt = ready[(ready.index(cur) + 1) % len(ready)]
        else:
            nxt = ready[0]
        _STATE["current"] = nxt
        _STATE["advanced_at"] = _now()
        _save_state()
        return nxt


def current_id():
    with _LOCK:
        cur = _STATE.get("current")
        if cur and _has_frame(cur) and any(
                s["id"] == cur and s.get("enabled") for s in _SOURCES):
            return cur
    return advance()


# ---- Background scraper ---------------------------------------------------
def scraper_loop():
    while True:
        try:
            for src in list(_enabled_ordered()):
                fetch_source(src)
            # Make sure something is selected once frames exist.
            if current_id() is None:
                pass
            if AUTO_ADVANCE_SEC > 0 and _now() - _STATE.get("advanced_at", 0) >= AUTO_ADVANCE_SEC:
                advance()
        except Exception:  # noqa: BLE001 — never let the loop die
            pass
        time.sleep(30)


# ---- HTTP -----------------------------------------------------------------
class Handler(BaseHTTPRequestHandler):
    server_version = "comics-display/1.0"

    def log_message(self, *a):  # quiet
        pass

    def _send(self, code, body, ctype="application/json", extra=None):
        if isinstance(body, str):
            body = body.encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("Access-Control-Allow-Origin", "*")
        for k, v in (extra or {}).items():
            self.send_header(k, v)
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def _json(self, code, obj):
        self._send(code, json.dumps(obj), "application/json")

    def _serve_frame(self, sid, ext):
        if not sid:
            return self._send(503, "no comic available", "text/plain")
        ppath, bpath = _pool_paths(sid)
        path = ppath if ext == "png" else bpath
        try:
            with open(path, "rb") as f:
                data = f.read()
        except Exception:  # noqa: BLE001
            return self._send(503, "frame missing", "text/plain")
        ctype = "image/png" if ext == "png" else "image/bmp"
        self._send(200, data, ctype, extra={"X-Comic-Source": sid})

    def _body_json(self):
        n = int(self.headers.get("Content-Length", 0) or 0)
        if not n:
            return {}
        try:
            return json.loads(self.rfile.read(n).decode("utf-8", "replace"))
        except Exception:  # noqa: BLE001
            return {}

    # -- routing --
    def do_HEAD(self):
        self.do_GET()

    def do_GET(self):
        path = urlsplit(self.path).path
        if path == "/":
            return self._send(200, PAGE_HTML, "text/html; charset=utf-8")
        if path in ("/current.png", "/current.bmp"):
            return self._serve_frame(current_id(), path.rsplit(".", 1)[1])
        if path in ("/next.png", "/next.bmp"):
            return self._serve_frame(advance(), path.rsplit(".", 1)[1])
        if path == "/api/state":
            return self._json(200, self._state_obj())
        if path.startswith("/preview/"):
            sid = path[len("/preview/"):].rsplit(".", 1)[0]
            return self._serve_frame(sid if _has_frame(sid) else None, "png")
        return self._send(404, "not found", "text/plain")

    def do_POST(self):
        path = urlsplit(self.path).path
        if path == "/api/sources":
            return self._add_source(self._body_json())
        if path == "/api/next":
            advance()
            return self._json(200, self._state_obj())
        parts = path.strip("/").split("/")
        if len(parts) == 4 and parts[0] == "api" and parts[1] == "sources":
            sid, action = parts[2], parts[3]
            if action == "toggle":
                return self._toggle(sid)
            if action == "refresh":
                return self._refresh(sid)
        return self._send(404, "not found", "text/plain")

    def do_DELETE(self):
        parts = urlsplit(self.path).path.strip("/").split("/")
        if len(parts) == 3 and parts[0] == "api" and parts[1] == "sources":
            return self._delete(parts[2])
        return self._send(404, "not found", "text/plain")

    # -- api impl --
    def _state_obj(self):
        with _LOCK:
            srcs = []
            for s in _SOURCES:
                m = _META.get(s["id"], {})
                srcs.append({**s, "status": {
                    "ok": m.get("ok"), "error": m.get("error"),
                    "fetched_at": m.get("fetched_at"),
                    "palette_used": m.get("palette_used"),
                    "has_frame": _has_frame(s["id"]),
                }})
            return {"current": _STATE.get("current"),
                    "auto_advance_sec": AUTO_ADVANCE_SEC,
                    "refresh_sec": REFRESH_SEC,
                    "sources": srcs}

    def _add_source(self, body):
        t = (body.get("type") or "").strip()
        name = (body.get("name") or "").strip()
        if t not in FETCHERS:
            return self._json(400, {"error": "type must be one of %s"
                                    % ", ".join(FETCHERS)})
        if not name:
            return self._json(400, {"error": "name required"})
        # Derive a stable id from the name; ensure uniqueness.
        base = "".join(c.lower() if c.isalnum() else "-" for c in name).strip("-") or "src"
        with _LOCK:
            sid, i = base, 1
            existing = {s["id"] for s in _SOURCES}
            while sid in existing:
                i += 1
                sid = "%s-%d" % (base, i)
            src = {"id": sid, "name": name, "type": t,
                   "palette": (body.get("palette") or "auto"),
                   "enabled": bool(body.get("enabled", True))}
            for k in ("url", "slug", "mode"):
                if body.get(k):
                    src[k] = body[k].strip()
            _SOURCES.append(src)
            _save_sources()
        # Kick an immediate fetch so the UI shows a result fast.
        threading.Thread(target=fetch_source, args=(src,),
                         kwargs={"force": True}, daemon=True).start()
        return self._json(200, {"ok": True, "id": sid})

    def _find(self, sid):
        for s in _SOURCES:
            if s["id"] == sid:
                return s
        return None

    def _toggle(self, sid):
        with _LOCK:
            s = self._find(sid)
            if not s:
                return self._json(404, {"error": "no such source"})
            s["enabled"] = not s.get("enabled")
            _save_sources()
        return self._json(200, {"ok": True, "enabled": s["enabled"]})

    def _refresh(self, sid):
        s = self._find(sid)
        if not s:
            return self._json(404, {"error": "no such source"})
        ok = fetch_source(s, force=True)
        return self._json(200, {"ok": ok, "status": _META.get(sid, {})})

    def _delete(self, sid):
        with _LOCK:
            s = self._find(sid)
            if not s:
                return self._json(404, {"error": "no such source"})
            _SOURCES.remove(s)
            _META.pop(sid, None)
            for p in _pool_paths(sid):
                try:
                    os.remove(p)
                except OSError:
                    pass
            if _STATE.get("current") == sid:
                _STATE["current"] = None
            _save_sources()
            _save_state()
        return self._json(200, {"ok": True})


# ---- Web UI ---------------------------------------------------------------
PAGE_HTML = """<!doctype html><html lang=en><head><meta charset=utf-8>
<meta name=viewport content="width=device-width,initial-scale=1">
<title>comics-display</title><style>
:root{color-scheme:dark}
body{margin:0;font:15px/1.5 system-ui,sans-serif;background:#121212;color:#e6e6e6}
header{padding:16px 20px;background:#1c1c1e;border-bottom:1px solid #2c2c2e}
h1{margin:0;font-size:19px}h1 small{color:#8e8e93;font-weight:400;font-size:13px}
main{max-width:920px;margin:0 auto;padding:20px}
.preview{background:#000;border:1px solid #2c2c2e;border-radius:10px;padding:10px;text-align:center;margin-bottom:20px}
.preview img{max-width:100%;image-rendering:pixelated;border-radius:4px}
.bar{display:flex;gap:10px;align-items:center;flex-wrap:wrap;margin-top:10px}
button{background:#0a84ff;color:#fff;border:0;border-radius:8px;padding:8px 14px;font-size:14px;cursor:pointer}
button.sec{background:#2c2c2e}button.warn{background:#5c1f1f}
table{width:100%;border-collapse:collapse}
th,td{text-align:left;padding:9px 8px;border-bottom:1px solid #262628;font-size:14px;vertical-align:middle}
th{color:#8e8e93;font-weight:500}
.dot{display:inline-block;width:9px;height:9px;border-radius:50%;margin-right:6px}
.ok{background:#30d158}.bad{background:#ff453a}.off{background:#48484a}
.muted{color:#8e8e93;font-size:12px}
.add{background:#1c1c1e;border:1px solid #2c2c2e;border-radius:10px;padding:16px;margin-top:22px}
.add h2{margin:0 0 12px;font-size:16px}
.row{display:flex;gap:10px;flex-wrap:wrap;align-items:end;margin-bottom:10px}
label{display:flex;flex-direction:column;gap:4px;font-size:12px;color:#8e8e93}
input,select{background:#2c2c2e;color:#fff;border:1px solid #3a3a3c;border-radius:7px;padding:8px;font-size:14px;min-width:150px}
code{background:#2c2c2e;padding:1px 5px;border-radius:4px;font-size:12px}
</style></head><body>
<header><h1>comics-display <small>&nbsp;reTerminal E1002 &middot; 800&times;480 &middot; Spectra&nbsp;6</small></h1></header>
<main>
<div class=preview>
  <img id=pv alt="current comic" src="/current.png">
  <div class=bar>
    <button onclick="next()">Next &rarr;</button>
    <button class=sec onclick="load()">Reload preview</button>
    <span class=muted id=curlbl></span>
    <span class=muted style=margin-left:auto>device URL: <code id=devurl></code></span>
  </div>
</div>

<table><thead><tr><th>Source</th><th>Type</th><th>Palette</th><th>Status</th><th></th></tr></thead>
<tbody id=rows></tbody></table>

<div class=add>
  <h2>Add a source</h2>
  <div class=row>
    <label>Name<input id=n placeholder="e.g. Garfield"></label>
    <label>Type<select id=t onchange="hint()">
      <option value=xkcd>xkcd (API)</option>
      <option value=gocomics>gocomics (slug)</option>
      <option value=farside>farside (daily dose)</option>
      <option value=ogimage>og:image (any page URL)</option>
      <option value=image>image (direct URL)</option>
    </select></label>
    <label>Palette<select id=p>
      <option value=auto>auto</option><option value=color>color</option><option value=mono>mono</option>
    </select></label>
    <label id=argwrap>Argument<input id=arg placeholder="slug or URL"></label>
    <button onclick="add()">Add</button>
  </div>
  <div class=muted id=hint></div>
</div>
</main>
<script>
const $=s=>document.querySelector(s);
function fmtAge(t){if(!t)return"never";const s=Math.floor(Date.now()/1000)-t;
 if(s<90)return s+"s ago";if(s<5400)return Math.floor(s/60)+"m ago";
 if(s<172800)return Math.floor(s/3600)+"h ago";return Math.floor(s/86400)+"d ago";}
function load(){$("#pv").src="/current.png?"+Date.now();
 $("#devurl").textContent=location.origin+"/next.png";
 fetch("/api/state").then(r=>r.json()).then(render);}
function render(st){
 $("#curlbl").textContent=st.current?("showing: "+st.current):"no comic ready";
 const rows=st.sources.map(s=>{
  const m=s.status||{};
  const cls=!s.enabled?"off":(m.ok?"ok":"bad");
  const stat=!s.enabled?"disabled":(m.ok?("ok &middot; "+fmtAge(m.fetched_at)+(m.palette_used?(" &middot; "+m.palette_used):"")):
    ("<span title=\\""+(m.error||"").replace(/"/g,"&quot;")+"\\">error</span>"+(m.has_frame?" (using last good)":"")));
  const arg=s.slug||s.url||s.mode||"";
  return `<tr><td><span class="dot ${cls}"></span>${s.name}${arg?` <span class=muted>${arg}</span>`:""}</td>
   <td>${s.type}</td><td>${s.palette||"auto"}</td><td class=muted>${stat}</td>
   <td style=white-space:nowrap>
    <button class=sec onclick="ref('${s.id}')">Refresh</button>
    <button class=sec onclick="tog('${s.id}')">${s.enabled?"Disable":"Enable"}</button>
    <button class=warn onclick="del('${s.id}')">Drop</button></td></tr>`;
 }).join("");
 $("#rows").innerHTML=rows||"<tr><td colspan=5 class=muted>no sources yet</td></tr>";
}
function next(){fetch("/api/next",{method:"POST"}).then(load);}
function tog(id){fetch("/api/sources/"+id+"/toggle",{method:"POST"}).then(load);}
function ref(id){fetch("/api/sources/"+id+"/refresh",{method:"POST"}).then(load);}
function del(id){if(confirm("Drop this source?"))fetch("/api/sources/"+id,{method:"DELETE"}).then(load);}
function hint(){const t=$("#t").value;const w=$("#argwrap"),h=$("#hint");
 if(t=="gocomics"){w.style.display="";$("#arg").placeholder="slug (e.g. calvinandhobbes, garfield, peanuts)";
   h.innerHTML="GoComics URL slug — the bit after gocomics.com/. Pulls today's strip.";}
 else if(t=="ogimage"||t=="image"){w.style.display="";$("#arg").placeholder="https://…";
   h.innerHTML=t=="ogimage"?"Any comic page URL; uses its og:image (works for most sites).":"A direct link to an image file.";}
 else{w.style.display="none";h.innerHTML=t=="xkcd"?"Random XKCD via its JSON API — no argument needed.":"The Far Side daily dose homepage — no argument needed.";}}
function add(){const t=$("#t").value,body={name:$("#n").value,type:t,palette:$("#p").value};
 const a=$("#arg").value.trim();
 if(t=="gocomics")body.slug=a;else if(t=="ogimage"||t=="image")body.url=a;
 fetch("/api/sources",{method:"POST",headers:{"Content-Type":"application/json"},body:JSON.stringify(body)})
  .then(r=>r.json()).then(j=>{if(j.error)alert(j.error);else{$("#n").value="";$("#arg").value="";setTimeout(load,600);}});}
hint();load();setInterval(load,15000);
</script></body></html>"""


# ---- Bootstrap ------------------------------------------------------------
def _bootstrap():
    os.makedirs(POOL_DIR, exist_ok=True)
    global _SOURCES, _STATE
    if os.path.exists(SOURCES_PATH):
        _SOURCES = _load_json(SOURCES_PATH, {"sources": []}).get("sources", [])
    else:
        _SOURCES = [dict(s) for s in DEFAULT_SOURCES]
        _save_sources()
    _STATE.update(_load_json(STATE_PATH, {}))
    _STATE.setdefault("current", None)


def main():
    _bootstrap()
    threading.Thread(target=scraper_loop, daemon=True).start()
    srv = ThreadingHTTPServer(("0.0.0.0", PORT), Handler)
    print("comics-display on :%d  data=%s  panel=%dx%d" % (PORT, DATA_DIR, W, H),
          flush=True)
    srv.serve_forever()


if __name__ == "__main__":
    main()
