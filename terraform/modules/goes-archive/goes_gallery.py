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

from PIL import Image, ImageDraw, ImageFont

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
                 os.environ.get("GOES_CROP_BOX", "1878,758,2321,1000").split(","))
HOME_LAT = float(os.environ.get("GOES_HOME_LAT", "37.30"))
HOME_LON = float(os.environ.get("GOES_HOME_LON", "-89.52"))
_win = os.environ.get("GOES_LOCAL_SCAN_WINDOW", "0.020,0.020").split(",")
LOCAL_DX, LOCAL_DY = float(_win[0]), float(_win[-1])
MESO_MAX_AGE = int(os.environ.get("GOES_MESO_MAX_AGE_SEC", "1800"))
PUBLIC_BASE = os.environ.get("GOES_PUBLIC_BASE", "").rstrip("/")
INDEX_TTL = int(os.environ.get("GOES_INDEX_TTL", "30"))
THUMB_W = int(os.environ.get("GOES_THUMB_W", "340"))
# Full-res source PNGs are huge (Full Disk 5424² ≈ 23 MB). The viewer serves a
# downscaled JPEG "preview" (≈0.6 MB) instead; a "full resolution" link still
# points at the raw PNG. Thumbs + previews are JPEG and pre-generated in the
# background so nothing is decoded on-demand.
PREVIEW_W = int(os.environ.get("GOES_PREVIEW_W", "2048"))
JPEG_Q = int(os.environ.get("GOES_JPEG_Q", "82"))
PREGEN_INTERVAL = int(os.environ.get("GOES_PREGEN_INTERVAL", "45"))
# Map overlay (drawn rack-side via the GOES projection — SatDump only ships
# coastline/country shapefiles, not US state lines). On for the headline by default.
OVERLAY_ON = os.environ.get("GOES_OVERLAY", "1") == "1"
STATES_GEOJSON = os.environ.get("GOES_STATES_GEOJSON", "/opt/goes-archive/us_states.geojson")
HOME_LABEL = os.environ.get("GOES_HOME_LABEL", "Cape Girardeau")

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


# ---- map overlay (state lines, cities, home marker) ------------------------
# Curated regional cities (name, lat, lon); only those landing in-frame are drawn.
CITIES = [
    ("St. Louis", 38.63, -90.20), ("Memphis", 35.15, -90.05),
    ("Nashville", 36.16, -86.78), ("Louisville", 38.25, -85.76),
    ("Little Rock", 34.74, -92.29), ("Kansas City", 39.10, -94.58),
    ("Springfield MO", 37.21, -93.29), ("Evansville", 37.97, -87.57),
    ("Paducah", 37.08, -88.60), ("Indianapolis", 39.77, -86.16),
    ("Chicago", 41.88, -87.63), ("Tulsa", 36.15, -95.99),
]
COL_STATE = (255, 214, 64)      # amber state lines
COL_CITY = (245, 245, 245)
COL_HOME = (255, 70, 70)
_STATES = {"rings": None}


def _state_rings():
    """US state boundary rings as [(lon,lat),...], loaded once from the GeoJSON."""
    if _STATES["rings"] is None:
        rings = []
        try:
            with open(STATES_GEOJSON) as f:
                gj = json.load(f)
            for feat in gj.get("features", []):
                g = feat.get("geometry") or {}
                cs = g.get("coordinates") or []
                polys = cs if g.get("type") == "MultiPolygon" else (
                    [cs] if g.get("type") == "Polygon" else [])
                for poly in polys:
                    for ring in poly:
                        rings.append([(pt[0], pt[1]) for pt in ring])
        except (OSError, ValueError, KeyError, TypeError) as e:
            log(f"states geojson load failed ({STATES_GEOJSON}): {e}")
            rings = []
        _STATES["rings"] = rings
    return _STATES["rings"]


def projector(cfg):
    """f(lat,lon)->(col,row) in the cfg image's pixel grid (None off-disk).

    Inverts SatDump's geos projection_cfg: col=(x*alt-offset_x)/scalar_x (x = scan
    angle from latlon_to_scan). Validated against Cape's known full-disk pixel.
    """
    try:
        alt = float(cfg["altitude"]); ox = float(cfg["offset_x"]); oy = float(cfg["offset_y"])
        sx = float(cfg["scalar_x"]); sy = float(cfg["scalar_y"]); lon0 = float(cfg.get("lon0", -75.0))
    except (KeyError, TypeError, ValueError):
        return None

    def f(lat, lon):
        s = latlon_to_scan(lat, lon, lon0)
        if not s:
            return None
        return (s[0] * alt - ox) / sx, (s[1] * alt - oy) / sy
    return f


def draw_overlay(img, cfg, ox=0, oy=0, layers=("states", "cities", "home")):
    """Draw map overlays onto a PIL image. cfg = the SOURCE image's projection_cfg;
    (ox,oy) = the source-pixel origin if img is a crop of that source (else 0,0)."""
    proj = projector(cfg)
    if not proj:
        return img.convert("RGB")
    im = img.convert("RGB")
    d = ImageDraw.Draw(im)
    W, H = im.size
    lw = max(1, round(W / 1200))
    fsize = max(11, round(W / 90))
    try:
        font = ImageFont.load_default(size=fsize)
    except TypeError:                       # older Pillow: fixed-size default only
        font = ImageFont.load_default()

    def px(lat, lon):
        p = proj(lat, lon)
        return (p[0] - ox, p[1] - oy) if p else None

    if "states" in layers:
        for ring in _state_rings():
            seg = []
            for lon, lat in ring:
                p = px(lat, lon)
                if p and -W < p[0] < 2 * W and -H < p[1] < 2 * H:
                    seg.append(p)
                elif len(seg) > 1:          # break the polyline at off-frame points
                    d.line(seg, fill=COL_STATE, width=lw); seg = []
                else:
                    seg = []
            if len(seg) > 1:
                d.line(seg, fill=COL_STATE, width=lw)
    if "cities" in layers:
        r = max(2, lw + 1)
        for name, lat, lon in CITIES:
            p = px(lat, lon)
            if not p or not (0 <= p[0] < W and 0 <= p[1] < H):
                continue
            x, y = p
            d.ellipse([x - r, y - r, x + r, y + r], fill=COL_CITY, outline=(0, 0, 0))
            d.text((x + r + 2, y - fsize // 2), name, fill=COL_CITY, font=font,
                   stroke_width=1, stroke_fill=(0, 0, 0))
    if "home" in layers:
        p = px(HOME_LAT, HOME_LON)
        if p and 0 <= p[0] < W and 0 <= p[1] < H:
            x, y = p
            r = max(5, lw + 4)
            d.ellipse([x - r, y - r, x + r, y + r], outline=COL_HOME, width=lw + 1)
            d.line([x - r - 3, y, x + r + 3, y], fill=COL_HOME, width=lw)
            d.line([x, y - r - 3, x, y + r + 3], fill=COL_HOME, width=lw)
            d.text((x + r + 4, y - fsize), HOME_LABEL, fill=COL_HOME, font=font,
                   stroke_width=1, stroke_fill=(0, 0, 0))
    return im


def _ensure_overlay(relpath, layers=("states", "cities", "home")):
    """Overlay a full archive image (no crop); cache under derived/overlay/.
    Returns the cached relpath, or None (caller falls back to the raw image)."""
    src = _safe_path(relpath)
    if not src:
        return None
    cfg = read_projection(os.path.dirname(src))
    if not cfg:
        return None
    out = os.path.join(DERIVED, "overlay", relpath)
    try:
        if os.path.exists(out) and os.path.getmtime(out) >= os.path.getmtime(src):
            return os.path.relpath(out, ARCHIVE)
        os.makedirs(os.path.dirname(out), exist_ok=True)
        with Image.open(src) as im:
            draw_overlay(im, cfg, 0, 0, layers).save(out)
        return os.path.relpath(out, ARCHIVE)
    except (OSError, ValueError) as e:
        log(f"overlay failed {src}: {e}")
        return None


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


def _product_label(name):
    """L2 product filename -> human label, e.g.
    'abi_rgb_AWG_Cloud_Height_Algorithm_(ACHA).png' -> 'AWG Cloud Height Algorithm (ACHA)'."""
    n = (name or "").rsplit("/", 1)[-1]
    for suf in ("_map.png", ".png"):
        if n.endswith(suf):
            n = n[: -len(suf)]
    if n.startswith("abi_rgb_"):
        n = n[len("abi_rgb_"):]
    return n.replace("_", " ").strip() or "product"


def _group_for(kind, sat, sector, preferred):
    """The browse-tab label for a capture. GOES-19 imagery keeps its plain sector
    names (the primary feed); other satellites and L2 products are prefixed so they
    sort into their own tabs."""
    if kind == "L2":
        return "L2 · " + _product_label(preferred)
    if sat == "GOES-19":
        return sector
    if sat in ("NWS", "Unknown"):
        return sat
    return f"{sat} · {sector}"


def _scan_archive():
    """Walk IMAGES/<sat>/<sector>/<ts>/ AND L2/<sat>/<sector>/<ts>/ -> capture
    records (newest first). Multi-satellite (GOES-19 East, GOES-18 West rebroadcast,
    NWS, Unknown) + L2 derived products. OSError-tolerant (in-flight rsync)."""
    caps = []
    for kind in ("IMAGES", "L2"):
        base = os.path.join(ARCHIVE, kind)
        try:
            sats = [e for e in os.scandir(base) if e.is_dir()]
        except OSError:
            continue
        for sat in sats:
            try:
                sectors = [e for e in os.scandir(sat.path) if e.is_dir()]
            except OSError:
                continue
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
                    pref = ((PREFERRED + ".png") if (PREFERRED + ".png") in pngs
                            else (composites[0] if composites else bands[0]))
                    caps.append({
                        "id": f"{kind}/{sat.name}/{sec.name}/{td.name}".replace(" ", "_"),
                        "kind": kind,
                        "satellite": sat.name,
                        "sector": sec.name,
                        "group": _group_for(kind, sat.name, sec.name, pref),
                        "timestamp": ts,
                        "dir": os.path.relpath(td.path, ARCHIVE),
                        "composites": composites,
                        "bands": bands,
                        "preferred": pref,
                    })
    caps.sort(key=lambda c: c["timestamp"], reverse=True)
    return caps


def get_index(force=False):
    """Cached archive index; rescans on TTL expiry or when IMAGES/L2 mtime changed."""
    now = time.time()
    src_mtime = 0.0
    for k in ("IMAGES", "L2"):
        try:
            src_mtime += os.stat(os.path.join(ARCHIVE, k)).st_mtime
        except OSError:
            pass
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


def latest_in(sector, caps, sat="GOES-19"):
    for c in caps:                                # caps already newest-first
        if c["sector"] == sector and c["satellite"] == sat:
            return c
    return None


# ---- headline (the weather2 image) -----------------------------------------
def _ensure_crop(capture, composite):
    """Crop a Full Disk composite to the Cape box (+ overlay if on); cache under
    DERIVED. Returns relpath."""
    src = os.path.join(ARCHIVE, capture["dir"], composite)
    out_dir = os.path.join(DERIVED, capture["dir"])
    suffix = "__cape_ov.png" if OVERLAY_ON else "__cape.png"
    out = os.path.join(out_dir, composite.replace(".png", suffix))
    rel = os.path.relpath(out, ARCHIVE)
    try:
        if os.path.exists(out) and os.path.getmtime(out) >= os.path.getmtime(src):
            return rel
        os.makedirs(out_dir, exist_ok=True)
        with Image.open(src) as im:
            crop = im.crop(CROP_BOX)
            if OVERLAY_ON:
                cfg = read_projection(os.path.join(ARCHIVE, capture["dir"]))
                if cfg:
                    crop = draw_overlay(crop, cfg, CROP_BOX[0], CROP_BOX[1])
            crop.save(out)
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
            if OVERLAY_ON:
                rel = _ensure_overlay(rel) or rel    # overlaid mesoscale, else raw
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
def _scaled(relpath, maxdim, subdir):
    """Cached ≤maxdim JPEG of an archive image under derived/<subdir>/. Returns the
    absolute path, or None. Decoding the 5424² source is the cost (~1s), so these
    are cached and pre-generated (see _pregen_loop) — never made on the hot path
    if it can be helped."""
    src = _safe_path(relpath)
    if not src:
        return None
    out = os.path.join(DERIVED, subdir, relpath.replace(os.sep, "__") + ".jpg")
    try:
        if os.path.exists(out) and os.path.getmtime(out) >= os.path.getmtime(src):
            return out
        os.makedirs(os.path.dirname(out), exist_ok=True)
        with Image.open(src) as im:
            im.thumbnail((maxdim, maxdim))
            im.convert("RGB").save(out, "JPEG", quality=JPEG_Q, optimize=True)
        return out
    except (OSError, ValueError) as e:
        log(f"scale failed {src}: {e}")
        return None


def ensure_thumb(relpath):
    """Cached JPEG grid thumbnail."""
    return _scaled(relpath, THUMB_W, "thumbs")


def ensure_preview(relpath):
    """Cached JPEG viewer preview (≤PREVIEW_W) — what the dialog shows by default
    instead of the 23 MB raw PNG."""
    return _scaled(relpath, PREVIEW_W, "preview")


def _pregen_loop():
    """Background worker: pre-generate the grid thumbnail + viewer preview for each
    capture's preferred composite, so browsing never blocks on a ~1s PNG decode.
    Only missing/stale ones are (re)built; new captures are picked up each pass."""
    while True:
        try:
            for c in get_index():
                pref = c.get("preferred")
                if pref:
                    rel = os.path.join(c["dir"], pref)
                    ensure_thumb(rel)
                    ensure_preview(rel)
        except Exception as e:  # noqa: BLE001
            log(f"pregen: {e}")
        time.sleep(PREGEN_INTERVAL)


# ---- path safety -----------------------------------------------------------
_ARCHIVE_REAL = os.path.realpath(ARCHIVE)


def _safe_path(relpath):
    """Resolve relpath under the archive root; None if it escapes (../, absolute)."""
    p = os.path.realpath(os.path.join(ARCHIVE, relpath))
    if p == _ARCHIVE_REAL or p.startswith(_ARCHIVE_REAL + os.sep):
        return p if os.path.isfile(p) else None
    return None


# ---- EMWIN (NWS text bulletins + weather graphics off the HRIT feed) --------
EMWIN_DIR = os.path.join(ARCHIVE, "EMWIN")
# A_<TTAAII(6)><CCCC(4)><DDHHMM(6)>_C_KWIN_<YYYYMMDDHHMMSS>_<seq>-<n>-<NAME>.<ext>
EMWIN_RE = re.compile(r"^A_(\w{2})\w{4}(\w{4})\d{6}_C_KWIN_\d{14}_.*-(.+)\.(\w+)$")
_TT_CAT = {  # WMO T1T2 -> broad category (for the filter chips)
    "FP": "Forecast", "FA": "Aviation", "FT": "Aviation", "FB": "Aviation",
    "FZ": "Marine", "FE": "Marine", "FQ": "Marine", "FW": "Fire Wx", "FO": "Forecast",
    "WW": "Watch/Warn", "WS": "Winter", "WF": "Warning", "WO": "Warning",
    "WU": "Warning", "WC": "Warning", "WH": "Hurricane", "WT": "Tropical", "WA": "Aviation",
    "SR": "Hydro", "SU": "Hydro", "SA": "Surface Obs", "SM": "Synoptic",
    "SP": "Special", "SX": "Obs", "SO": "Obs", "SS": "Marine Obs", "SI": "Obs",
    "NO": "Notice", "NP": "Notice", "NW": "Notice", "NT": "Test", "NX": "Notice",
    "AS": "Summary", "AC": "Convective", "AX": "Analysis", "AW": "Analysis", "AE": "Analysis",
    "TI": "Satellite", "TX": "Misc", "CD": "Climate", "CS": "Climate",
}
_CAT_FALLBACK = {"F": "Forecast", "W": "Warning", "S": "Obs", "N": "Notice",
                 "A": "Analysis", "U": "Upper Air", "T": "Misc", "C": "Climate"}
_EMWIN = {"items": [], "scanned": 0.0, "mtime": -1.0}
_ELOCK = threading.Lock()


def _emwin_cat(tt):
    return _TT_CAT.get(tt) or _CAT_FALLBACK.get(tt[:1], "Other")


def _emwin_scan():
    items = []
    try:
        ents = list(os.scandir(EMWIN_DIR))
    except OSError:
        return []
    for e in ents:
        if not e.is_file():
            continue
        try:
            mt = int(e.stat().st_mtime)
        except OSError:
            continue
        ext = e.name.rsplit(".", 1)[-1].lower()
        typ = "text" if ext == "txt" else "graphic"
        m = EMWIN_RE.match(e.name)
        if m:
            tt, cccc, name, _ = m.groups()
            items.append({"file": e.name, "office": cccc, "cat": _emwin_cat(tt),
                          "name": name, "type": typ, "ts": mt})
        else:
            items.append({"file": e.name, "office": "", "cat": "Other",
                          "name": e.name, "type": typ, "ts": mt})
    items.sort(key=lambda x: x["ts"], reverse=True)
    return items


def emwin_index():
    """Cached EMWIN product list (newest first); rescans on TTL or dir change."""
    now = time.time()
    try:
        mtime = os.stat(EMWIN_DIR).st_mtime
    except OSError:
        mtime = -1.0
    with _ELOCK:
        if (now - _EMWIN["scanned"] < INDEX_TTL) and _EMWIN["mtime"] == mtime:
            return _EMWIN["items"]
    items = _emwin_scan()
    with _ELOCK:
        _EMWIN["items"] = items
        _EMWIN["scanned"] = now
        _EMWIN["mtime"] = mtime
        return items


# ---- L2 product legends (colorbar from SatDump's LUT + nominal GOES-R range) -
LUT_DIR = os.environ.get("GOES_LUT_DIR",
                         os.path.join(os.path.dirname(os.path.abspath(__file__)), "luts"))
# Product name (the L2 composite) -> {lut, unit, lo, hi, label}. The gradient is
# exact (SatDump's LUT); the value range is the standard GOES-R L2 product range
# the 8-bit DPI maps over (shown as "nominal").
L2_SCALES = {
    "AWG Cloud Height Algorithm (ACHA)": {"lut": "acha.png", "unit": "km", "lo": 0, "hi": 18, "label": "Cloud-top height"},
    "Cloud top Temperature (ACHT)":      {"lut": "acht.png", "unit": "°C", "lo": -90, "hi": 30, "label": "Cloud-top temperature"},
    "Derived Stability Indices - CAPE":  {"lut": "dsi-cape.png", "unit": "J/kg", "lo": 0, "hi": 5000, "label": "CAPE (instability)"},
    "Land Surface Temperature":          {"lut": "lst.png", "unit": "°C", "lo": -25, "hi": 50, "label": "Land surface temperature"},
    "Sea Surface Temperature":           {"lut": "sst.png", "unit": "°C", "lo": -2, "hi": 35, "label": "Sea surface temperature"},
    "Total Precipitable Water":          {"lut": "tpw.png", "unit": "mm", "lo": 0, "hi": 60, "label": "Total precipitable water"},
    "Rain Rate Per Quarter Hour":        {"lut": "rrqpe.png", "unit": "mm/hr", "lo": 0, "hi": 50, "label": "Rain rate"},
}
_LUT_CACHE = {}


def _lut_colors(lut):
    """Sampled hex colors across a SatDump LUT PNG (a 256-wide ramp). Cached."""
    if lut in _LUT_CACHE:
        return _LUT_CACHE[lut]
    cols = []
    try:
        with Image.open(os.path.join(LUT_DIR, lut)) as im:
            im = im.convert("RGB")
            w = im.width
            px = im.load()
            for i in range(64):                       # 64 stops -> smooth CSS gradient
                x = min(w - 1, round(i * (w - 1) / 63))
                r, g, b = px[x, 0]
                cols.append("#%02x%02x%02x" % (r, g, b))
    except (OSError, ValueError) as e:
        log(f"lut load {lut}: {e}")
    _LUT_CACHE[lut] = cols
    return cols


def legend_for_group(group):
    """Legend descriptor for an 'L2 · <product>' browse group, or None."""
    if not group or not group.startswith("L2 · "):
        return None
    s = L2_SCALES.get(group[len("L2 · "):])
    if not s:
        return None
    cols = _lut_colors(s["lut"])
    if not cols:
        return None
    return {"label": s["label"], "unit": s["unit"], "lo": s["lo"], "hi": s["hi"],
            "mid": round((s["lo"] + s["hi"]) / 2, 1), "colors": cols}


# ---- animated loops (WebP + GIF) -------------------------------------------
ANIM_W = int(os.environ.get("GOES_ANIM_W", "1100"))      # loop frame max dimension
ANIM_MAXN = int(os.environ.get("GOES_ANIM_MAXN", "48"))


def _anim_sources(group, comp, n):
    """Most-recent-N (group, composite) original relpaths, oldest->newest."""
    caps = [c for c in get_index() if c["group"] == group][:max(2, min(ANIM_MAXN, n))]
    rels = []
    for c in reversed(caps):                       # oldest -> newest = forward play
        use = comp if comp and (comp in c["composites"] or comp in c["bands"]) else c.get("preferred")
        if use:
            rels.append(os.path.join(c["dir"], use))
    return rels


def ensure_anim(group, comp, n, ms, fmt):
    """Build (and cache) an animated WebP/GIF loop from the recent frames. Frames
    come from the cached previews (fast) downscaled to ANIM_W."""
    fmt = "gif" if fmt == "gif" else "webp"
    rels = _anim_sources(group, comp, n)
    if len(rels) < 2:
        return None
    previews = [ensure_preview(r) for r in rels]
    previews = [p for p in previews if p]
    if len(previews) < 2:
        return None
    latest = max(os.path.getmtime(p) for p in previews)
    safe = (group + "_" + (comp or "pref")).replace("/", "_").replace(" ", "_").replace("·", "-")
    out = os.path.join(DERIVED, "anim", f"{safe}_n{len(previews)}_ms{ms}.{fmt}")
    try:
        if os.path.exists(out) and os.path.getmtime(out) >= latest:
            return out
        os.makedirs(os.path.dirname(out), exist_ok=True)
        frames = []
        for p in previews:
            with Image.open(p) as im:
                f = im.convert("RGB")
                f.thumbnail((ANIM_W, ANIM_W))
                frames.append(f.copy())
        if fmt == "gif":
            base = frames[0].convert("P", palette=Image.ADAPTIVE, colors=256)
            pal = [f.quantize(palette=base, dither=Image.FLOYDSTEINBERG) for f in frames]
            pal[0].save(out, format="GIF", save_all=True, append_images=pal[1:],
                        duration=ms, loop=0, optimize=True, disposal=2)
        else:
            frames[0].save(out, format="WEBP", save_all=True, append_images=frames[1:],
                           duration=ms, loop=0, quality=72, method=4)
        return out
    except (OSError, ValueError) as e:
        log(f"anim {group}/{comp}: {e}")
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
dialog img{display:block;max-width:94vw;max-height:78vh;width:auto;height:auto}
#legend{padding:.6rem 1rem .8rem}#legend:empty{display:none}
#legend .lt{font-size:.8rem;font-weight:600;margin-bottom:.3rem}
#legend .lb{height:16px;border-radius:4px;border:1px solid var(--line)}
#legend .lx{display:flex;justify-content:space-between;font-size:.72rem;color:var(--dim);margin-top:.2rem;font-variant-numeric:tabular-nums}
#legend .ln{font-size:.66rem;color:var(--dim);opacity:.7;margin-top:.1rem}
dialog .dh{display:flex;justify-content:space-between;align-items:center;gap:1rem;padding:.6rem 1rem;border-bottom:1px solid var(--line)}
dialog .dh select,dialog .dh button{background:#1a2433;color:var(--text);border:1px solid var(--line);border-radius:7px;padding:.35rem .6rem;font:inherit;font-size:.82rem;cursor:pointer}
</style></head><body>
<header><h1>🛰 GOES-19 HRIT</h1><span class="dim" id="sub">live archive · Cape Girardeau</span><a href="/emwin" style="margin-left:auto;color:var(--accent);text-decoration:none;font-size:.9rem">📰 EMWIN ▸</a><span class="dim" id="space" style="margin-left:1rem"></span></header>
<div class="wrap">
<div class="hero"><img id="hero" alt="latest local image"><div class="cap"><span id="herometa">loading…</span><span class="dim">headline · auto local</span></div></div>
<div class="tabs" id="tabs"></div>
<div class="grid" id="grid"><div class="empty">loading…</div></div>
</div>
<dialog id="dlg"><div class="dh"><select id="comp"></select><label class="dim" style="display:flex;align-items:center;gap:.3rem"><input type="checkbox" id="ovl">overlay</label><button id="loopbtn" class="dim" style="background:#1a2433;color:var(--text);border:1px solid var(--line);border-radius:7px;padding:.2rem .55rem;cursor:pointer">&#9654; Loop</button><span id="loopctl" style="display:none;align-items:center;gap:.4rem"><input type="range" id="lframes" min="6" max="48" value="18" style="width:88px"><span class="dim" id="lframesn">18f</span><select id="lspeed" style="background:#0d1420;color:var(--text);border:1px solid var(--line);border-radius:6px;padding:.15rem"><option value="400">slow</option><option value="250" selected>med</option><option value="120">fast</option></select><a class="dim" id="gifdl" style="text-decoration:underline">&#8595; GIF</a></span><a class="dim" id="full" target="_blank" rel="noopener" style="text-decoration:underline">full res &#8595;</a><span class="dim" id="dlgmeta"></span><button id="dlgx">close</button></div><img id="dlgimg" alt=""><div id="legend"></div></dialog>
<script>
var $=function(i){return document.getElementById(i)};var IMG="/api/goes/image/";
var GROUPS=[];var cur=null;var CAPS=[];
function esc(s){return String(s).replace(/[&<>"]/g,function(m){return{'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'}[m]})}
function fmt(t){return t?new Date(t*1000).toLocaleString():''}
function ago(s){if(s<90)return s+'s ago';if(s<5400)return Math.round(s/60)+'m ago';return Math.round(s/3600)+'h ago'}
function loadHero(){fetch('/api/goes/latest',{cache:'no-store'}).then(function(r){return r.json()}).then(function(d){
  if(!d||!d.image_url){$('herometa').textContent='no captures yet';return;}
  $('hero').src=d.image_url+(d.image_url.indexOf('?')<0?'?t='+d.timestamp:'');
  $('herometa').innerHTML=esc(d.sector)+' · '+esc((d.source||'').replace('-',' '))+' · '+fmt(d.timestamp)+' ('+ago(d.age_sec||0)+')';
}).catch(function(){})}
function tabs(){$('tabs').innerHTML=GROUPS.map(function(g){return '<button class="tab'+(g.group===cur?' on':'')+'" data-s="'+esc(g.group)+'">'+esc(g.group)+' <small style="opacity:.6">'+g.count+'</small></button>'}).join('');
  Array.prototype.forEach.call($('tabs').children,function(b){b.onclick=function(){cur=b.getAttribute('data-s');tabs();loadCaps();}});}
function render(){var cs=CAPS;
  $('grid').innerHTML=cs.length?cs.map(function(c){var t=c.preferred?(IMG+'thumb/'+encodeURI(c.dir+'/'+c.preferred)):'';
    return '<div class="card" data-id="'+esc(c.id)+'"><img loading="lazy" src="'+t+'"><div class="m"><b>'+fmt(c.timestamp)+'</b>'+c.composites.length+' composite(s) · '+c.bands.length+' band(s)</div></div>'}).join(''):'<div class="empty">no captures in this group yet</div>';
  Array.prototype.forEach.call($('grid').children,function(el){el.addEventListener('click',function(){open(el.getAttribute('data-id'))})});}
var looping=false;
function open(id){var c=CAPS.find(function(x){return x.id===id});if(!c)return;
  var opts=c.composites.concat(c.bands);
  $('comp').innerHTML=opts.map(function(o){return '<option value="'+esc(o)+'">'+esc(o.replace('abi_rgb_','').replace(/_/g,' ').replace('.png',''))+'</option>'}).join('');
  $('dlgmeta').textContent=c.sector+' · '+fmt(c.timestamp);
  function animQS(fmt){return '/api/goes/anim?group='+encodeURIComponent(c.group||'')+'&comp='+encodeURIComponent($('comp').value)+'&n='+$('lframes').value+'&ms='+$('lspeed').value+'&fmt='+fmt;}
  function show(){
    if(looping){$('lframesn').textContent=$('lframes').value+'f';$('gifdl').href=animQS('gif');
      $('loopbtn').innerHTML='&#8987; building…';
      $('dlgimg').onload=function(){if(looping)$('loopbtn').innerHTML='&#10073;&#10073; Still';};
      $('dlgimg').onerror=function(){if(looping)$('loopbtn').innerHTML='&#9888; too few frames';};
      $('dlgimg').src=animQS('webp');return;}
    $('dlgimg').onload=null;$('dlgimg').onerror=null;
    var rel=encodeURI(c.dir+'/'+$('comp').value);
    $('dlgimg').src=$('ovl').checked?(IMG+rel+'?overlay=1'):(IMG+'preview/'+rel);  // light preview, not the 23MB raw
    $('full').href=IMG+rel;}
  function setLoop(on){looping=on;$('loopctl').style.display=on?'inline-flex':'none';
    $('loopbtn').innerHTML=on?'&#10073;&#10073; Still':'&#9654; Loop';$('ovl').parentNode.style.opacity=on?'.4':'1';show();}
  $('loopbtn').onclick=function(){setLoop(!looping)};
  $('lframes').oninput=function(){if(looping)show()};$('lspeed').onchange=function(){if(looping)show()};
  $('comp').value=c.preferred||opts[0];setLoop(false);$('comp').onchange=show;$('ovl').onchange=show;
  $('legend').innerHTML='';
  fetch('/api/goes/legend?group='+encodeURIComponent(c.group||''),{cache:'no-store'}).then(function(r){return r.json()}).then(function(g){
    if(!g||!g.colors)return;
    $('legend').innerHTML='<div class="lt">'+esc(g.label)+'</div><div class="lb" style="background:linear-gradient(to right,'+g.colors.join(',')+')"></div><div class="lx"><span>'+g.lo+'</span><span>'+g.mid+'</span><span>'+g.hi+' '+esc(g.unit)+'</span></div><div class="ln">nominal GOES-R product range</div>';
  }).catch(function(){});
  $('dlg').showModal();}
$('dlgx').onclick=function(){$('dlg').close()};
function loadGroups(){fetch('/api/goes/groups',{cache:'no-store'}).then(function(r){return r.json()}).then(function(d){GROUPS=d.groups||[];if(!cur&&GROUPS.length)cur=GROUPS[0].group;tabs();loadCaps();}).catch(function(){})}
function loadCaps(){if(!cur)return;fetch('/api/goes/captures?group='+encodeURIComponent(cur)+'&recent=180',{cache:'no-store'}).then(function(r){return r.json()}).then(function(d){CAPS=d.captures||[];render();}).catch(function(){})}
function loadSpace(){fetch('/api/goes/space',{cache:'no-store'}).then(function(r){return r.json()}).then(function(d){if(d.free_gb!=null)$('space').textContent=d.free_gb+' GB free · '+(d.captures||0)+' captures';}).catch(function(){})}
loadHero();loadGroups();loadSpace();setInterval(loadHero,60000);setInterval(function(){loadGroups();loadCaps();},60000);
</script></body></html>"""


PAGE_EMWIN = """<!doctype html><html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>GOES EMWIN</title><style>
:root{--bg:#0a0e16;--panel:#141b27;--line:#243245;--text:#e6edf5;--dim:#8a99b0;--accent:#4ea1ff}
*{box-sizing:border-box;margin:0;padding:0}
body{background:var(--bg);color:var(--text);font:14px/1.45 system-ui,-apple-system,sans-serif;height:100vh;display:flex;flex-direction:column}
header{padding:10px 16px;border-bottom:1px solid var(--line);display:flex;align-items:center;gap:12px;flex-wrap:wrap}
header h1{font-size:1rem;font-weight:650}a{color:var(--accent);text-decoration:none}.dim{color:var(--dim);font-size:.82rem}
.bar{padding:8px 16px;border-bottom:1px solid var(--line);display:flex;gap:.5rem;flex-wrap:wrap;align-items:center}
.bar input,.bar select{background:#0d1420;color:var(--text);border:1px solid var(--line);border-radius:7px;padding:.35rem .5rem;font:inherit;font-size:.85rem}
.chip{background:#1a2433;color:var(--text);border:1px solid var(--line);border-radius:999px;padding:.25rem .6rem;font-size:.76rem;cursor:pointer;display:inline-block;margin:.1rem}
.chip.on{background:var(--accent);color:#08111d;border-color:var(--accent);font-weight:600}
.main{flex:1;display:flex;min-height:0}
.list{width:42%;max-width:540px;overflow:auto;border-right:1px solid var(--line)}
.row{display:flex;gap:.5rem;padding:.5rem .8rem;border-bottom:1px solid var(--line);cursor:pointer;align-items:baseline}
.row:hover{background:#131b28}.row.on{background:#16223a}
.row time{color:var(--dim);font-size:.72rem;white-space:nowrap;width:3.2rem;flex:none}
.row .cat{font-size:.64rem;border:1px solid var(--line);border-radius:999px;padding:0 .4rem;color:var(--dim);white-space:nowrap;flex:none}
.row .nm{font-weight:600;font-size:.82rem;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;flex:1}
.row .of{color:var(--dim);font-size:.72rem;flex:none}
.view{flex:1;overflow:auto;padding:1rem 1.2rem;min-width:0}
.view pre{white-space:pre-wrap;font:13px/1.5 ui-monospace,Menlo,monospace;color:#dce6f1}
.view img{max-width:100%;height:auto;background:#000;border-radius:8px}
.view .ph{color:var(--dim);margin-top:2rem;text-align:center}
@media(max-width:760px){.main{flex-direction:column}.list{width:100%;max-width:none;max-height:46vh;border-right:0;border-bottom:1px solid var(--line)}}
</style></head><body>
<header><h1>📰 GOES EMWIN</h1><span class="dim">NWS bulletins &amp; weather graphics off the HRIT feed</span><a href="/" style="margin-left:auto">🛰 Imagery &#9656;</a></header>
<div class="bar">
  <input id="q" placeholder="search…" style="flex:1;min-width:110px">
  <select id="type"><option value="">all types</option><option value="text">text</option><option value="graphic">graphics</option></select>
  <select id="office"><option value="">all offices</option></select>
</div>
<div class="bar" id="cats"></div>
<div class="main"><div class="list" id="list"></div><div class="view" id="view"><div class="ph">select a product to view</div></div></div>
<script>
var $=function(i){return document.getElementById(i)};var ITEMS=[],cat='',built=false;
function esc(s){return String(s).replace(/[&<>"]/g,function(m){return{'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'}[m]})}
function clock(t){return new Date(t*1000).toLocaleTimeString([],{hour:'2-digit',minute:'2-digit'})}
function load(){
  var u='/api/goes/emwin?recent=400';
  if(cat)u+='&cat='+encodeURIComponent(cat);
  if($('office').value)u+='&office='+encodeURIComponent($('office').value);
  if($('q').value)u+='&q='+encodeURIComponent($('q').value);
  fetch(u,{cache:'no-store'}).then(function(r){return r.json()}).then(function(d){
    var tf=$('type').value;
    ITEMS=(d.items||[]).filter(function(i){return !tf||i.type===tf});
    if(!built){buildCats(d.cats);buildOffices(d.offices);built=true;}
    renderList();
  }).catch(function(){})
}
function buildCats(cats){$('cats').innerHTML='<span class="chip on" data-c="">all</span>'+(cats||[]).map(function(c){return '<span class="chip" data-c="'+esc(c[0])+'">'+esc(c[0])+' '+c[1]+'</span>'}).join('');
  Array.prototype.forEach.call($('cats').children,function(ch){ch.onclick=function(){cat=ch.getAttribute('data-c');Array.prototype.forEach.call($('cats').children,function(x){x.classList.remove('on')});ch.classList.add('on');load();}});}
function buildOffices(off){$('office').innerHTML='<option value="">all offices</option>'+(off||[]).map(function(o){return '<option value="'+esc(o[0])+'">'+esc(o[0])+' ('+o[1]+')</option>'}).join('');}
function renderList(){$('list').innerHTML=ITEMS.map(function(i){return '<div class="row" data-f="'+esc(i.file)+'"><time>'+clock(i.ts)+'</time><span class="cat">'+esc(i.cat)+'</span><span class="nm">'+(i.type==='graphic'?'\\uD83D\\uDDBC ':'')+esc(i.name)+'</span><span class="of">'+esc(i.office)+'</span></div>'}).join('')||'<div class="ph" style="padding:1rem">no products</div>';
  Array.prototype.forEach.call($('list').children,function(el){el.addEventListener('click',function(){view(el.getAttribute('data-f'),el)})});}
function view(file,el){if(!file)return;
  Array.prototype.forEach.call($('list').children,function(x){x.classList.remove('on')});if(el)el.classList.add('on');
  var url='/api/goes/emwin/file/'+encodeURIComponent(file);
  if(/\\.(gif|jpe?g|png)$/i.test(file)){$('view').innerHTML='<img src="'+url+'" alt="">';}
  else{fetch(url,{cache:'no-store'}).then(function(r){return r.text()}).then(function(t){$('view').innerHTML='<pre>'+esc(t)+'</pre>';}).catch(function(){$('view').innerHTML='<div class="ph">failed to load</div>';});}}
$('q').addEventListener('input',function(){clearTimeout(window._t);window._t=setTimeout(load,300)});
$('type').onchange=load;$('office').onchange=load;
load();setInterval(load,60000);
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
        ct = ("image/jpeg" if path.endswith(".jpg") else
              "image/webp" if path.endswith(".webp") else
              "image/gif" if path.endswith(".gif") else "image/png")
        self.send_response(200)
        self.send_header("Content-Type", ct)
        if path.endswith(".gif"):       # nudge a download for the shareable GIF
            self.send_header("Content-Disposition", 'attachment; filename="goes-loop.gif"')
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", f"public, max-age={max_age}")
        self._cors()
        self.end_headers()
        self.wfile.write(data)

    def _html(self, body):
        b = body.encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(b)))
        self.end_headers()
        self.wfile.write(b)

    def _text(self, path):
        try:
            with open(path, "rb") as f:
                data = f.read()
        except OSError:
            return self._json(404, {"error": "not found"})
        self.send_response(200)
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "public, max-age=86400")
        self._cors()
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        raw, _, qs = self.path.partition("?")
        path = unquote(raw)               # decode %20 etc. before any path use
        params = {k: v[-1] for k, v in parse_qs(qs).items()}
        if path == "/" or path == "/index.html":
            self._html(PAGE)
        elif path == "/emwin":
            self._html(PAGE_EMWIN)
        elif path == "/api/goes/emwin":
            items = emwin_index()
            sel = items
            cat, office, q = params.get("cat"), params.get("office"), params.get("q", "").upper()
            if cat:
                sel = [i for i in sel if i["cat"] == cat]
            if office:
                sel = [i for i in sel if i["office"] == office]
            if q:
                sel = [i for i in sel if q in i["file"].upper() or q in i["name"].upper()]
            try:
                n = int(params.get("recent", "300"))
            except ValueError:
                n = 300
            cats, offices = {}, {}
            for i in items:
                cats[i["cat"]] = cats.get(i["cat"], 0) + 1
                if i["office"]:
                    offices[i["office"]] = offices.get(i["office"], 0) + 1
            self._json(200, {"items": sel[:n], "total": len(sel),
                             "cats": sorted(cats.items(), key=lambda x: -x[1]),
                             "offices": sorted(offices.items())})
        elif path.startswith("/api/goes/emwin/file/"):
            name = path[len("/api/goes/emwin/file/"):]
            p = _safe_path(os.path.join("EMWIN", name))
            if not p:
                self._json(404, {"error": "not found"})
            elif name.lower().endswith(".txt"):
                self._text(p)
            else:
                self._file(p)
        elif path == "/api/goes/latest":
            self._json(200, headline())
        elif path == "/api/goes/groups":
            # Distinct browse tabs (ordered) with counts + newest timestamp.
            order = {"Full Disk": 0, "Mesoscale 1": 1, "Mesoscale 2": 2}
            g = {}
            for c in get_index():
                e = g.setdefault(c["group"], {"group": c["group"], "count": 0, "latest": 0})
                e["count"] += 1
                e["latest"] = max(e["latest"], c["timestamp"])
            groups = sorted(g.values(), key=lambda e: (
                order.get(e["group"], 3 if not e["group"].startswith("L2") else 4),
                e["group"]))
            self._json(200, {"groups": groups})
        elif path == "/api/goes/captures":
            caps = get_index()
            grp = params.get("group")
            sector = params.get("sector")
            if grp:
                caps = [c for c in caps if c["group"] == grp]
            elif sector:
                caps = [c for c in caps if c["sector"] == sector]
            try:
                n = int(params.get("recent", "0"))
            except ValueError:
                n = 0
            self._json(200, {"captures": caps[:n] if n > 0 else caps,
                             "total": len(caps), "preferred": PREFERRED})
        elif path == "/api/goes/legend":
            self._json(200, legend_for_group(params.get("group", "")) or {})
        elif path == "/api/goes/anim":
            try:
                n = int(params.get("n", "18")); ms = int(params.get("ms", "250"))
            except ValueError:
                n, ms = 18, 250
            ms = max(40, min(2000, ms))
            fmt = "gif" if params.get("fmt") == "gif" else "webp"
            p = ensure_anim(params.get("group", ""), params.get("comp", ""), n, ms, fmt)
            self._file(p, max_age=300) if p else self._json(404, {"error": "need >= 2 frames"})
        elif path.startswith("/api/goes/image/thumb/"):
            rel = path[len("/api/goes/image/thumb/"):]
            t = ensure_thumb(rel)
            self._file(t) if t else self._json(404, {"error": "not found"})
        elif path.startswith("/api/goes/image/preview/"):
            rel = path[len("/api/goes/image/preview/"):]
            p = ensure_preview(rel)
            self._file(p) if p else self._json(404, {"error": "not found"})
        elif path.startswith("/api/goes/image/"):
            rel = path[len("/api/goes/image/"):]
            if params.get("overlay") == "1":      # gallery toggle: annotate on demand
                rel = _ensure_overlay(rel) or rel
            p = _safe_path(rel)
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
    threading.Thread(target=_pregen_loop, daemon=True, name="pregen").start()
    log(f"goes-gallery on :{PORT} archive={ARCHIVE} sat={SAT} "
        f"preferred={PREFERRED} crop={CROP_BOX} cbor2={cbor2 is not None} "
        f"home_scan={HOME_SCAN} thumb={THUMB_W} preview={PREVIEW_W}")
    ThreadingHTTPServer(("0.0.0.0", PORT), Handler).serve_forever()


if __name__ == "__main__":
    main()
