#!/usr/bin/env python3
"""goes_gallery.py — browsable GOES archive + the weather2 headline API (goes.rg2.io).

The GOES Pi (goes.srvr) decodes GOES-19 HRIT live with SatDump and this rack LXC
rsync-pulls the image products into GOES_ARCHIVE_DIR. This service:

  * serves a browsable gallery of recent captures (Full Disk + the two roaming
    Mesoscale sectors), grouped by sector, newest first, with cached thumbnails;
  * serves /api/goes/latest — the single "current local image" the weather2
    widget (tools/goes-embed.html) embeds. GOES-19 HRIT emits only Full Disk +
    two Mesoscale sectors (no fixed CONUS), and the mesoscale floaters roam, so
    the headline is normally the Full Disk **cropped** to a fixed Cape-Girardeau
    box (GOES is geostationary, so the crop is constant), and falls back to a
    Mesoscale sector only when one is actually parked over the local area.

The cropped headline defaults to the Clean Longwave IR composite — it carries
cloud structure day AND night (False Color is a daytime-only visible product,
black at the local pre-dawn hours).

Stdlib + Pillow (crop/thumbnail) + cbor2 (read SatDump's projection_cfg to place
the mesoscale sectors). All read-only; pruning is a separate systemd timer.

Env: GOES_PORT (8095), GOES_ARCHIVE_DIR (/var/lib/goes-archive), GOES_SAT
     (GOES-19), GOES_PREFERRED_COMPOSITE (abi_rgb_Clean_Longwave_IR_Window_Band),
     GOES_CROP_BOX ("left,top,right,bottom" px in the 5424² full disk),
     GOES_HOME_LAT/LON (Cape Girardeau), GOES_LOCAL_SCAN_WINDOW ("dx,dy" rad —
     how close a mesoscale centre must be to home to win the headline),
     GOES_MESO_MAX_AGE_SEC (1800), GOES_PUBLIC_BASE (e.g. https://goes.rg2.io for
     absolute image URLs in the embed), GOES_INDEX_TTL (30).
"""
import calendar
import json
import math
import os
import re
import shutil
import threading
import time
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, quote, unquote

from PIL import Image

try:
    import cbor2
except ImportError:                       # mesoscale fallback degrades to crop-only
    cbor2 = None

PORT = int(os.environ.get("GOES_PORT", "8095"))
ARCHIVE = os.environ.get("GOES_ARCHIVE_DIR", "/var/lib/goes-archive")
SAT = os.environ.get("GOES_SAT", "GOES-19")
IMAGES_ROOT = os.path.join(ARCHIVE, "IMAGES", SAT)
DERIVED = os.environ.get("GOES_DERIVED_DIR", os.path.join(ARCHIVE, "derived"))
PREFERRED = os.environ.get("GOES_PREFERRED_COMPOSITE",
                           "abi_rgb_Clean_Longwave_IR_Window_Band")
CROP_BOX = tuple(int(x) for x in
                 os.environ.get("GOES_CROP_BOX", "1688,660,2480,1144").split(","))
HOME_LAT = float(os.environ.get("GOES_HOME_LAT", "37.30"))
HOME_LON = float(os.environ.get("GOES_HOME_LON", "-89.52"))
_win = os.environ.get("GOES_LOCAL_SCAN_WINDOW", "0.020,0.020").split(",")
LOCAL_DX, LOCAL_DY = float(_win[0]), float(_win[-1])
MESO_MAX_AGE = int(os.environ.get("GOES_MESO_MAX_AGE_SEC", "1800"))
PUBLIC_BASE = os.environ.get("GOES_PUBLIC_BASE", "").rstrip("/")
INDEX_TTL = int(os.environ.get("GOES_INDEX_TTL", "30"))
THUMB_W = int(os.environ.get("GOES_THUMB_W", "360"))

# A timestamped capture dir, e.g. "2026-06-29_11-30-21" (UTC, matches the Z files).
TS_RE = re.compile(r"^\d{4}-\d{2}-\d{2}_\d{2}-\d{2}-\d{2}$")


def log(msg):
    print(msg, flush=True)


# ---- GOES-R ABI fixed-grid geostationary projection (PUG vol.3) -------------
# Forward: geodetic lat/lon -> satellite scan angles (x=E/W, y=N/S) in radians.
# We compare *scan angles* directly (home vs a mesoscale centre) for the locality
# test, so no inverse projection is needed. lon0 is the sub-satellite longitude
# from SatDump's projection_cfg (-75.0 for GOES-East).
R_EQ = 6378137.0
R_POL = 6356752.31414
H = 42164160.0                            # altitude + r_eq (PUG perspective point)
E2 = 1.0 - (R_POL ** 2) / (R_EQ ** 2)


def latlon_to_scan(lat_deg, lon_deg, lon0_deg=-75.0):
    """(lat, lon) degrees -> (x, y) scan angle radians, or None if off the disk."""
    phi = math.radians(lat_deg)
    lam = math.radians(lon_deg)
    lam0 = math.radians(lon0_deg)
    phi_c = math.atan((R_POL ** 2 / R_EQ ** 2) * math.tan(phi))
    rc = R_POL / math.sqrt(1.0 - E2 * math.cos(phi_c) ** 2)
    sx = H - rc * math.cos(phi_c) * math.cos(lam - lam0)
    sy = -rc * math.cos(phi_c) * math.sin(lam - lam0)
    sz = rc * math.sin(phi_c)
    # Visibility: the point must be on the near face of the geoid.
    if H * (H - sx) < sy * sy + (R_EQ ** 2 / R_POL ** 2) * sz * sz:
        return None
    y = math.atan(sz / sx)
    x = math.asin(-sy / math.sqrt(sx * sx + sy * sy + sz * sz))
    return x, y


def proj_center_scan(cfg):
    """Centre scan angle (x, y) of a SatDump geos projection_cfg, or None.

    SatDump stores projected metres: X = offset_x + col*scalar_x (and Y likewise),
    where X = scan_angle * altitude. The image centre is at (width/2, height/2).
    """
    try:
        if cfg.get("type") != "geos":
            return None
        alt = float(cfg["altitude"])
        cx = float(cfg["offset_x"]) + (float(cfg["width"]) / 2.0) * float(cfg["scalar_x"])
        cy = float(cfg["offset_y"]) + (float(cfg["height"]) / 2.0) * float(cfg["scalar_y"])
        return cx / alt, cy / alt
    except (KeyError, TypeError, ValueError, ZeroDivisionError):
        return None


HOME_SCAN = latlon_to_scan(HOME_LAT, HOME_LON)    # computed once at boot


def read_projection(capture_dir):
    """projection_cfg dict from a capture's product.cbor, or None."""
    if cbor2 is None:
        return None
    pc = os.path.join(capture_dir, "product.cbor")
    try:
        with open(pc, "rb") as f:
            return cbor2.load(f).get("projection_cfg")
    except (OSError, ValueError, KeyError):
        return None


def mesoscale_is_local(capture_dir):
    """True if this mesoscale sector's centre sits within the home scan window."""
    if HOME_SCAN is None:
        return False
    cfg = read_projection(capture_dir)
    c = proj_center_scan(cfg) if cfg else None
    if not c:
        return False
    return abs(c[0] - HOME_SCAN[0]) <= LOCAL_DX and abs(c[1] - HOME_SCAN[1]) <= LOCAL_DY


# ---- archive index ---------------------------------------------------------
_INDEX = {"captures": [], "scanned": 0.0, "src_mtime": -1.0}
_ILOCK = threading.Lock()


def _dir_unix(name):
    """'2026-06-29_11-30-21' (UTC) -> unix seconds, or None."""
    try:
        dt = datetime.strptime(name, "%Y-%m-%d_%H-%M-%S").replace(tzinfo=timezone.utc)
        return int(dt.timestamp())
    except ValueError:
        return None


def _scan_archive():
    """Walk IMAGES/<sat>/<sector>/<ts>/ -> sorted capture records (newest first).

    Cheap and OSError-tolerant: an in-flight rsync may be writing a capture dir,
    so a dir that vanishes or has no PNGs yet is just skipped this pass.
    """
    caps = []
    try:
        sectors = [e for e in os.scandir(IMAGES_ROOT) if e.is_dir()]
    except OSError:
        return []
    for sec in sectors:
        try:
            tsdirs = [e for e in os.scandir(sec.path) if e.is_dir() and TS_RE.match(e.name)]
        except OSError:
            continue
        for td in tsdirs:
            ts = _dir_unix(td.name)
            if ts is None:
                continue
            try:
                pngs = [e.name for e in os.scandir(td.path)
                        if e.is_file() and e.name.endswith(".png")
                        and not e.name.endswith("_map.png")]
            except OSError:
                continue
            if not pngs:
                continue
            composites = sorted(n for n in pngs if n.startswith("abi_rgb_"))
            bands = sorted(n for n in pngs if not n.startswith("abi_rgb_"))
            rel = os.path.relpath(td.path, ARCHIVE)
            caps.append({
                "id": f"{sec.name}/{td.name}".replace(" ", "_"),
                "satellite": SAT,
                "sector": sec.name,
                "timestamp": ts,
                "dir": rel,                       # relpath under ARCHIVE
                "composites": composites,
                "bands": bands,
                "preferred": (PREFERRED + ".png") if (PREFERRED + ".png") in pngs
                else (composites[0] if composites else (bands[0] if bands else None)),
            })
    caps.sort(key=lambda c: c["timestamp"], reverse=True)
    return caps


def get_index(force=False):
    """Cached archive index; rescans on TTL expiry or when IMAGES mtime changed."""
    now = time.time()
    try:
        src_mtime = os.stat(IMAGES_ROOT).st_mtime
    except OSError:
        src_mtime = -1.0
    with _ILOCK:
        fresh = (now - _INDEX["scanned"] < INDEX_TTL) and _INDEX["src_mtime"] == src_mtime
        if fresh and not force:
            return _INDEX["captures"]
    caps = _scan_archive()                        # scan outside the lock
    with _ILOCK:
        _INDEX["captures"] = caps
        _INDEX["scanned"] = now
        _INDEX["src_mtime"] = src_mtime
        return caps


def latest_in(sector, caps):
    for c in caps:                                # caps already newest-first
        if c["sector"] == sector:
            return c
    return None


# ---- headline (the weather2 image) -----------------------------------------
def _ensure_crop(capture, composite):
    """Crop a Full Disk composite to the Cape box; cache under DERIVED. Returns relpath."""
    src = os.path.join(ARCHIVE, capture["dir"], composite)
    out_dir = os.path.join(DERIVED, capture["dir"])
    out = os.path.join(out_dir, composite.replace(".png", "__cape.png"))
    rel = os.path.relpath(out, ARCHIVE)
    try:
        if os.path.exists(out) and os.path.getmtime(out) >= os.path.getmtime(src):
            return rel
        os.makedirs(out_dir, exist_ok=True)
        with Image.open(src) as im:
            im.crop(CROP_BOX).save(out)
        return rel
    except (OSError, ValueError) as e:
        log(f"crop failed {src}: {e}")
        return None


def _image_url(relpath):
    # quote() keeps "/" safe; this encodes the spaces in sector names ("Full Disk").
    u = "/api/goes/image/" + quote(relpath.replace(os.sep, "/"))
    return (PUBLIC_BASE + u) if PUBLIC_BASE else u


def headline():
    """The current local image: a fresh local mesoscale if available, else the
    Cape-cropped Full Disk. Returns a JSON-able dict (or {} if the archive is empty)."""
    caps = get_index()
    if not caps:
        return {}
    now = time.time()
    # 1) Prefer a fresh mesoscale sector parked over the local area.
    for sector in ("Mesoscale 1", "Mesoscale 2"):
        m = latest_in(sector, caps)
        if not m or (now - m["timestamp"]) > MESO_MAX_AGE:
            continue
        cap_dir = os.path.join(ARCHIVE, m["dir"])
        if mesoscale_is_local(cap_dir) and m["preferred"]:
            rel = os.path.join(m["dir"], m["preferred"])
            return {"satellite": SAT, "sector": sector, "source": "mesoscale",
                    "composite": m["preferred"], "timestamp": m["timestamp"],
                    "age_sec": int(now - m["timestamp"]),
                    "image_url": _image_url(rel)}
    # 2) Fall back to the Cape-cropped Full Disk (always covers home, day or night).
    fd = latest_in("Full Disk", caps)
    if fd:
        comp = (PREFERRED + ".png") if (PREFERRED + ".png") in fd["composites"] \
            else (fd["composites"][0] if fd["composites"] else fd["preferred"])
        rel = _ensure_crop(fd, comp) if comp else None
        if rel:
            return {"satellite": SAT, "sector": "Full Disk", "source": "fulldisk-crop",
                    "composite": comp, "timestamp": fd["timestamp"],
                    "age_sec": int(now - fd["timestamp"]),
                    "image_url": _image_url(rel)}
    # 3) Last resort: newest anything, uncropped.
    c = caps[0]
    if c["preferred"]:
        rel = os.path.join(c["dir"], c["preferred"])
        return {"satellite": SAT, "sector": c["sector"], "source": "raw",
                "composite": c["preferred"], "timestamp": c["timestamp"],
                "age_sec": int(now - c["timestamp"]), "image_url": _image_url(rel)}
    return {}


# ---- thumbnails ------------------------------------------------------------
def ensure_thumb(relpath):
    """Cached THUMB_W-wide thumbnail for an archive image; returns its absolute path."""
    src = _safe_path(relpath)
    if not src:
        return None
    out = os.path.join(DERIVED, "thumbs", relpath.replace(os.sep, "__"))
    try:
        if os.path.exists(out) and os.path.getmtime(out) >= os.path.getmtime(src):
            return out
        os.makedirs(os.path.dirname(out), exist_ok=True)
        with Image.open(src) as im:
            im.thumbnail((THUMB_W, THUMB_W))
            im.convert("RGB").save(out, "PNG")
        return out
    except (OSError, ValueError) as e:
        log(f"thumb failed {src}: {e}")
        return None


# ---- path safety -----------------------------------------------------------
_ARCHIVE_REAL = os.path.realpath(ARCHIVE)


def _safe_path(relpath):
    """Resolve relpath under the archive root; None if it escapes (../, absolute)."""
    p = os.path.realpath(os.path.join(ARCHIVE, relpath))
    if p == _ARCHIVE_REAL or p.startswith(_ARCHIVE_REAL + os.sep):
        return p if os.path.isfile(p) else None
    return None


# ---- HTTP ------------------------------------------------------------------
PAGE = """<!doctype html><html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>GOES-19 — rg2.io</title><style>
:root{--bg:#0a0e16;--panel:#131b28;--line:#243245;--text:#e6edf5;--dim:#8a99b0;--accent:#4ea1ff}
*{box-sizing:border-box;margin:0;padding:0}
body{background:radial-gradient(circle at 50% -10%,#13233a 0%,var(--bg) 60%);color:var(--text);font:15px/1.5 system-ui,-apple-system,sans-serif;min-height:100vh}
header{padding:14px 20px;border-bottom:1px solid var(--line);display:flex;align-items:center;gap:12px;flex-wrap:wrap}
header h1{font-size:1.05rem;font-weight:650}.dim{color:var(--dim);font-size:.82rem}
.wrap{max-width:1200px;margin:0 auto;padding:1.2rem}
.hero{background:var(--panel);border:1px solid var(--line);border-radius:14px;overflow:hidden;margin-bottom:1.4rem}
.hero img{display:block;width:100%;height:auto;background:#000}
.hero .cap{padding:.7rem 1rem;display:flex;justify-content:space-between;gap:1rem;flex-wrap:wrap;font-size:.85rem;color:var(--dim)}
.tabs{display:flex;gap:.5rem;margin:0 0 1rem;flex-wrap:wrap}
.tab{background:#1a2433;color:var(--text);border:1px solid var(--line);border-radius:999px;padding:.35rem .9rem;font:inherit;font-size:.85rem;cursor:pointer}
.tab.on{background:var(--accent);color:#08111d;border-color:var(--accent);font-weight:600}
.grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(180px,1fr));gap:.8rem}
.card{background:var(--panel);border:1px solid var(--line);border-radius:10px;overflow:hidden;cursor:pointer;transition:border-color .15s}
.card:hover{border-color:var(--accent)}
.card img{display:block;width:100%;height:130px;object-fit:cover;background:#000}
.card .m{padding:.45rem .6rem;font-size:.74rem;color:var(--dim)}
.card .m b{color:var(--text);font-weight:600;display:block;font-size:.8rem}
.empty{color:var(--dim);padding:2rem;text-align:center}
dialog{border:1px solid var(--line);border-radius:12px;background:var(--panel);color:var(--text);max-width:96vw;max-height:96vh;padding:0}
dialog::backdrop{background:rgba(0,0,0,.7)}
dialog img{display:block;max-width:94vw;max-height:84vh;width:auto;height:auto}
dialog .dh{display:flex;justify-content:space-between;align-items:center;gap:1rem;padding:.6rem 1rem;border-bottom:1px solid var(--line)}
dialog .dh select,dialog .dh button{background:#1a2433;color:var(--text);border:1px solid var(--line);border-radius:7px;padding:.35rem .6rem;font:inherit;font-size:.82rem;cursor:pointer}
</style></head><body>
<header><h1>🛰 GOES-19 HRIT</h1><span class="dim" id="sub">live archive · Cape Girardeau</span><span class="dim" id="space" style="margin-left:auto"></span></header>
<div class="wrap">
<div class="hero"><img id="hero" alt="latest local image"><div class="cap"><span id="herometa">loading…</span><span class="dim">headline · auto local</span></div></div>
<div class="tabs" id="tabs"></div>
<div class="grid" id="grid"><div class="empty">loading…</div></div>
</div>
<dialog id="dlg"><div class="dh"><select id="comp"></select><span class="dim" id="dlgmeta"></span><button id="dlgx">close</button></div><img id="dlgimg" alt=""></dialog>
<script>
var $=function(i){return document.getElementById(i)};var IMG="/api/goes/image/";
var SECTORS=["Full Disk","Mesoscale 1","Mesoscale 2"];var cur="Full Disk";var CAPS=[];
function esc(s){return String(s).replace(/[&<>"]/g,function(m){return{'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'}[m]})}
function fmt(t){return t?new Date(t*1000).toLocaleString():''}
function ago(s){if(s<90)return s+'s ago';if(s<5400)return Math.round(s/60)+'m ago';return Math.round(s/3600)+'h ago'}
function loadHero(){fetch('/api/goes/latest',{cache:'no-store'}).then(function(r){return r.json()}).then(function(d){
  if(!d||!d.image_url){$('herometa').textContent='no captures yet';return;}
  $('hero').src=d.image_url+(d.image_url.indexOf('?')<0?'?t='+d.timestamp:'');
  $('herometa').innerHTML=esc(d.sector)+' · '+esc((d.source||'').replace('-',' '))+' · '+fmt(d.timestamp)+' ('+ago(d.age_sec||0)+')';
}).catch(function(){})}
function tabs(){$('tabs').innerHTML=SECTORS.map(function(s){return '<button class="tab'+(s===cur?' on':'')+'" data-s="'+esc(s)+'">'+esc(s)+'</button>'}).join('');
  Array.prototype.forEach.call($('tabs').children,function(b){b.onclick=function(){cur=b.getAttribute('data-s');tabs();render();}});}
function render(){var cs=CAPS.filter(function(c){return c.sector===cur});
  $('grid').innerHTML=cs.length?cs.map(function(c){var t=c.preferred?(IMG+'thumb/'+encodeURI(c.dir+'/'+c.preferred)):'';
    return '<div class="card" data-id="'+esc(c.id)+'"><img loading="lazy" src="'+t+'"><div class="m"><b>'+fmt(c.timestamp)+'</b>'+c.composites.length+' composite(s) · '+c.bands.length+' band(s)</div></div>'}).join(''):'<div class="empty">no captures in this sector yet</div>';
  Array.prototype.forEach.call($('grid').children,function(el){el.onclick&&(el.onclick=null);el.addEventListener('click',function(){open(el.getAttribute('data-id'))})});}
function open(id){var c=CAPS.find(function(x){return x.id===id});if(!c)return;
  var opts=c.composites.concat(c.bands);
  $('comp').innerHTML=opts.map(function(o){return '<option value="'+esc(o)+'">'+esc(o.replace('abi_rgb_','').replace(/_/g,' ').replace('.png',''))+'</option>'}).join('');
  $('dlgmeta').textContent=c.sector+' · '+fmt(c.timestamp);
  function show(){$('dlgimg').src=IMG+encodeURI(c.dir+'/'+$('comp').value)}
  $('comp').value=c.preferred||opts[0];show();$('comp').onchange=show;$('dlg').showModal();}
$('dlgx').onclick=function(){$('dlg').close()};
function loadCaps(){fetch('/api/goes/captures?recent=240',{cache:'no-store'}).then(function(r){return r.json()}).then(function(d){CAPS=d.captures||[];render();}).catch(function(){})}
function loadSpace(){fetch('/api/goes/space',{cache:'no-store'}).then(function(r){return r.json()}).then(function(d){if(d.free_gb!=null)$('space').textContent=d.free_gb+' GB free · '+(d.captures||0)+' captures';}).catch(function(){})}
tabs();loadHero();loadCaps();loadSpace();setInterval(loadHero,60000);setInterval(loadCaps,60000);
</script></body></html>"""


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def _cors(self):
        self.send_header("Access-Control-Allow-Origin", "*")

    def _json(self, code, obj):
        d = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(d)))
        self._cors()
        self.end_headers()
        self.wfile.write(d)

    def _file(self, path, max_age=86400):
        try:
            with open(path, "rb") as f:
                data = f.read()
        except OSError:
            return self._json(404, {"error": "not found"})
        self.send_response(200)
        self.send_header("Content-Type", "image/png")
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", f"public, max-age={max_age}")
        self._cors()
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        raw, _, qs = self.path.partition("?")
        path = unquote(raw)               # decode %20 etc. before any path use
        params = {k: v[-1] for k, v in parse_qs(qs).items()}
        if path == "/" or path == "/index.html":
            body = PAGE.encode()
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        elif path == "/api/goes/latest":
            self._json(200, headline())
        elif path == "/api/goes/captures":
            caps = get_index()
            sector = params.get("sector")
            if sector:
                caps = [c for c in caps if c["sector"] == sector]
            try:
                n = int(params.get("recent", "0"))
            except ValueError:
                n = 0
            self._json(200, {"captures": caps[:n] if n > 0 else caps,
                             "total": len(caps), "preferred": PREFERRED})
        elif path.startswith("/api/goes/image/thumb/"):
            rel = path[len("/api/goes/image/thumb/"):]
            t = ensure_thumb(rel)
            self._file(t) if t else self._json(404, {"error": "not found"})
        elif path.startswith("/api/goes/image/"):
            p = _safe_path(path[len("/api/goes/image/"):])
            self._file(p) if p else self._json(404, {"error": "not found"})
        elif path == "/api/goes/space":
            try:
                du = shutil.disk_usage(ARCHIVE)
                free_gb = round(du.free / 1e9, 1)
                used_gb = round(du.used / 1e9, 1)
            except OSError:
                free_gb = used_gb = None
            self._json(200, {"free_gb": free_gb, "used_gb": used_gb,
                             "captures": len(get_index()),
                             "cbor2": cbor2 is not None})
        else:
            self._json(404, {"error": "not found"})


def main():
    os.makedirs(DERIVED, exist_ok=True)
    log(f"goes-gallery on :{PORT} archive={ARCHIVE} sat={SAT} "
        f"preferred={PREFERRED} crop={CROP_BOX} cbor2={cbor2 is not None} "
        f"home_scan={HOME_SCAN}")
    ThreadingHTTPServer(("0.0.0.0", PORT), Handler).serve_forever()


if __name__ == "__main__":
    main()
