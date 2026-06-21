#!/usr/bin/env python3
"""wx_alert.py — NOAA Weather Radio page + SAME/EAS alert decoder (wx.rg2.io).

Serves a weather page (player for the continuous /wx.mp3 + a live alert banner)
and decodes SAME (Specific Area Message Encoding) alerts off the same audio:

    ffmpeg -i <wx.mp3> -f s16le -ar 22050 -ac 1 - | multimon-ng -a EAS -t raw -

On a decoded SAME header it parses the event (TOR/SVR/FFW…), the FIPS areas and
the valid time, then RESPONDS: shows the banner, fires a configurable webhook
(Home Assistant — announce on house speakers / push), and logs it. Stdlib only.

On an active alert it also pulls the live warning text from api.weather.gov (best
effort, matched by SAME geocode) and links the county's NWS hazards page. A right
rail lists the tri-state counties with on/off toggles (Cape Girardeau locked on);
the active set is persisted to WX_FIPS_STATE and gates which alerts fire.

Env: WX_PORT (8090), WX_DECODE_URL (internal mount to decode),
     WX_PUBLIC_URL (public mount for the page player), HA_WEBHOOK_URL (optional),
     WX_FIPS_FILTER (comma-separated SAME allowlist — SEEDS the active county set
     on first run; thereafter the page toggles own it), WX_FIPS_STATE (persisted
     active-set path, default /var/lib/radio-compute/wx-fips.json).
"""
import json
import os
import subprocess
import threading
import time
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT = int(os.environ.get("WX_PORT", "8090"))
DECODE_URL = os.environ.get("WX_DECODE_URL", "http://192.168.6.82:8000/wx.mp3")
PUBLIC_URL = os.environ.get("WX_PUBLIC_URL", "https://icecast.rg2.io/wx.mp3")
HA_WEBHOOK_URL = os.environ.get("HA_WEBHOOK_URL", "")
ALERT_LOG = os.environ.get("WX_ALERT_LOG", "/var/lib/radio-compute/wx-alerts.jsonl")
# ---- County allowlist ------------------------------------------------------
# The local NWR transmitter (KPAH, NWS Paducah) carries SAME for the whole
# tri-state region, so we alert ONLY for counties in the active set. Cape
# Girardeau (home) is locked on; the neighbours are toggled at runtime from the
# page and persisted to disk. Codes are compared on the trailing 5-digit FIPS
# (SSCCC) so a whole-county SAME code (P=0) and a partial one (P=1..9) both match.
FIPS_STATE = os.environ.get("WX_FIPS_STATE", "/var/lib/radio-compute/wx-fips.json")
ST_USPS = {"01": "AL", "05": "AR", "17": "IL", "18": "IN", "21": "KY",
           "29": "MO", "47": "TN"}                  # SAME state digits -> USPS

# fips: 6-digit SAME code. lat/lon = a point in the county for the NWS link.
COUNTIES = [
    {"fips": "029031", "name": "Cape Girardeau", "st": "MO", "lat": 37.30, "lon": -89.52, "locked": True},
    {"fips": "029017", "name": "Bollinger",      "st": "MO", "lat": 37.30, "lon": -89.97},
    {"fips": "029157", "name": "Perry",          "st": "MO", "lat": 37.72, "lon": -89.86},
    {"fips": "029201", "name": "Scott",          "st": "MO", "lat": 37.05, "lon": -89.57},
    {"fips": "017077", "name": "Alexander",      "st": "IL", "lat": 37.00, "lon": -89.18},
    {"fips": "017181", "name": "Union",          "st": "IL", "lat": 37.45, "lon": -89.24},
]
BY_FIPS5 = {c["fips"][-5:]: c for c in COUNTIES}
LOCKED = {c["fips"][-5:] for c in COUNTIES if c.get("locked")}
# Seed set used only when no state file exists yet: locked + the env allowlist.
_SEED = LOCKED | {c.strip()[-5:] for c in os.environ.get("WX_FIPS_FILTER", "").split(",") if c.strip()}


def load_active():
    """Active 5-digit FIPS set from disk (seeded on first run); locked always in."""
    try:
        with open(FIPS_STATE) as f:
            saved = {str(c)[-5:] for c in json.load(f)}
    except (OSError, ValueError):
        saved = set(_SEED)
    return saved | LOCKED


def save_active(active):
    try:
        os.makedirs(os.path.dirname(FIPS_STATE), exist_ok=True)
        tmp = FIPS_STATE + ".tmp"
        with open(tmp, "w") as f:
            json.dump(sorted(active | LOCKED), f)
        os.replace(tmp, FIPS_STATE)
    except OSError as e:  # noqa: BLE001
        print(f"save_active failed: {e}", flush=True)


ACTIVE_FIPS = load_active()                          # mutated by /api/counties

# SAME event code -> human name (the common NWS set; unknown codes fall through).
EVENT_NAMES = {
    "TOR": "Tornado Warning", "TOA": "Tornado Watch", "SVR": "Severe Thunderstorm Warning",
    "SVA": "Severe Thunderstorm Watch", "SVS": "Severe Weather Statement",
    "FFW": "Flash Flood Warning", "FFA": "Flash Flood Watch", "FFS": "Flash Flood Statement",
    "FLW": "Flood Warning", "FLA": "Flood Watch", "FLS": "Flood Statement",
    "WSW": "Winter Storm Warning", "WSA": "Winter Storm Watch", "BZW": "Blizzard Warning",
    "HWW": "High Wind Warning", "HWA": "High Wind Watch", "TRW": "Tropical Storm Warning",
    "HUW": "Hurricane Warning", "EWW": "Extreme Wind Warning", "DSW": "Dust Storm Warning",
    "EQW": "Earthquake Warning", "FRW": "Fire Warning", "CFW": "Coastal Flood Warning",
    "SMW": "Special Marine Warning", "EAN": "Emergency Action Notification",
    "RWT": "Required Weekly Test", "RMT": "Required Monthly Test", "DMO": "Practice/Demo",
    "ADR": "Administrative Message", "NPT": "National Periodic Test",
}
# Warnings that warrant the most aggressive response (red banner + priority webhook).
HIGH_PRIORITY = {"TOR", "SVR", "FFW", "EWW", "HUW", "EQW", "EAN", "BZW", "DSW", "FRW"}

STATE = {"active": None, "recent": [], "decoder": False, "updated": 0}
_LOCK = threading.Lock()


def log(msg):
    print(msg, flush=True)


def parse_same(header):
    """ZCZC-ORG-EEE-PSSCCC-...+TTTT-JJJHHMM-LLLLLLLL- -> alert dict (or None)."""
    h = header.strip().strip("-")
    if not h.startswith("ZCZC"):
        return None
    try:
        head, tail = h.split("+", 1)
        parts = head.split("-")            # ZCZC, ORG, EEE, area, area, ...
        org, event = parts[1], parts[2]
        areas = [p for p in parts[3:] if p]
        tbits = tail.split("-")            # TTTT, JJJHHMM, LLLLLLLL
        duration, issued, station = tbits[0], tbits[1], (tbits[2] if len(tbits) > 2 else "")
        ts = int(time.time())
        try:                               # +TTTT purge time is HHMM
            dur_secs = int(duration[:2]) * 3600 + int(duration[2:]) * 60
        except (ValueError, IndexError):
            dur_secs = 1800
        return {
            "event_code": event,
            "event": EVENT_NAMES.get(event, event),
            "org": org, "areas": areas, "duration": duration,
            "issued": issued, "station": station,
            "priority": event in HIGH_PRIORITY,
            "raw": h, "ts": ts, "expires": ts + (dur_secs or 1800),
        }
    except (IndexError, ValueError):
        ts = int(time.time())
        return {"event_code": "???", "event": "Unparsed SAME", "raw": h,
                "priority": False, "areas": [], "ts": ts, "expires": ts + 1800}


def fips_allowed(alert):
    """True if any of the alert's areas is in the active county set (trailing 5)."""
    with _LOCK:
        active = set(ACTIVE_FIPS)
    return any(a[-5:] in active for a in alert.get("areas", []))


def counties_payload():
    """County catalog + current enabled/locked flags + a per-county NWS link."""
    with _LOCK:
        active = set(ACTIVE_FIPS)
    return {"counties": [{
        "fips": c["fips"], "name": c["name"], "st": c["st"],
        "locked": bool(c.get("locked")), "enabled": c["fips"][-5:] in active,
        "url": nws_link(c["fips"]),
    } for c in COUNTIES]}


def nws_link(area):
    """Human NWS hazards page (MapClick by county point) for a SAME area code."""
    c = BY_FIPS5.get(area[-5:])
    if c:
        return f"https://forecast.weather.gov/MapClick.php?lat={c['lat']}&lon={c['lon']}"
    return "https://www.weather.gov/"


def fetch_nws_text(alert):
    """Best-effort: the live NWS warning text matching this SAME burst, or None.

    Queries api.weather.gov active alerts for each state in the alert's areas and
    matches on SAME geocode (preferring an exact event match). Network failures are
    swallowed — the banner still shows the raw SAME + a county link without text.
    """
    want = {a[-5:] for a in alert.get("areas", [])}
    states = {ST_USPS.get(a[-5:][:2]) for a in alert.get("areas", [])} - {None}
    code = alert.get("event_code", "")
    best = None
    for usps in states:
        try:
            req = urllib.request.Request(
                f"https://api.weather.gov/alerts/active?area={usps}",
                headers={"User-Agent": "wx-alert/1.0 (rg2.io homelab; robertegardner@gmail.com)",
                         "Accept": "application/geo+json"})
            with urllib.request.urlopen(req, timeout=10) as r:
                feats = json.load(r).get("features", [])
        except Exception:  # noqa: BLE001
            continue
        for ft in feats:
            p = ft.get("properties", {})
            same = {str(s)[-5:] for s in p.get("geocode", {}).get("SAME", [])}
            if not (same & want):
                continue
            cand = {"event": p.get("event") or "", "headline": p.get("headline") or "",
                    "areaDesc": p.get("areaDesc") or "", "description": p.get("description") or "",
                    "instruction": p.get("instruction") or ""}
            if EVENT_NAMES.get(code, "").lower() == str(p.get("event", "")).lower():
                return cand                 # exact event match wins
            best = best or cand
    return best


def enrich_alert_bg(alert):
    """Pull full NWS text in the background and attach it to the live alert dict."""
    text = fetch_nws_text(alert)
    if not text:
        return
    with _LOCK:
        alert["nws"] = text                 # same dict object that lives in STATE
        STATE["updated"] = int(time.time())
    log(f"nws text matched: {text.get('event')} / {text.get('areaDesc', '')[:50]}")


def fire_webhook(alert):
    if not HA_WEBHOOK_URL:
        return
    try:
        data = json.dumps(alert).encode()
        req = urllib.request.Request(HA_WEBHOOK_URL, data=data,
                                     headers={"Content-Type": "application/json",
                                              "User-Agent": "wx-alert/1.0"})
        urllib.request.urlopen(req, timeout=8)
        log(f"webhook fired: {alert['event']}")
    except Exception as e:  # noqa: BLE001
        log(f"webhook failed: {e}")


def handle_alert(alert):
    if alert.get("areas"):
        alert["nws_url"] = nws_link(alert["areas"][0])   # county hazards link, now
    with _LOCK:
        STATE["active"] = alert
        STATE["recent"] = ([alert] + STATE["recent"])[:25]
        STATE["updated"] = int(time.time())
    log(f"ALERT: {alert['event']} areas={alert.get('areas')} raw={alert['raw']}")
    try:
        os.makedirs(os.path.dirname(ALERT_LOG), exist_ok=True)
        with open(ALERT_LOG, "a") as f:
            f.write(json.dumps(alert) + "\n")
    except OSError:
        pass
    threading.Thread(target=fire_webhook, args=(alert,), daemon=True).start()
    threading.Thread(target=enrich_alert_bg, args=(alert,), daemon=True).start()


def decoder_loop():
    """ffmpeg(/wx.mp3) -> multimon-ng EAS; parse ZCZC headers forever."""
    while True:
        try:
            ff = subprocess.Popen(
                ["ffmpeg", "-hide_banner", "-loglevel", "error", "-i", DECODE_URL,
                 "-f", "s16le", "-ar", "22050", "-ac", "1", "-"],
                stdout=subprocess.PIPE)
            mm = subprocess.Popen(
                ["multimon-ng", "-a", "EAS", "-t", "raw", "-"],
                stdin=ff.stdout, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                text=True)
            with _LOCK:
                STATE["decoder"] = True
            log("decoder: ffmpeg|multimon-ng up")
            for line in mm.stdout:
                if "ZCZC" in line:
                    idx = line.find("ZCZC")
                    alert = parse_same(line[idx:])
                    if alert and fips_allowed(alert):
                        handle_alert(alert)
                    elif alert:
                        log(f"filtered: {alert['event']} areas={alert.get('areas')} "
                            f"not in active counties")
            ff.kill(); mm.kill()
        except Exception as e:  # noqa: BLE001
            log(f"decoder error: {e}")
        with _LOCK:
            STATE["decoder"] = False
        time.sleep(5)


PAGE = """<!doctype html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>NOAA Weather Radio</title>
<style>
:root{--bg:#0b0f17;--panel:#141b27;--line:#243245;--text:#e6edf5;--dim:#8a99b0;--accent:#4ea1ff;--green:#5ce08a;--red:#ff5a5a;--amber:#ffb03a}
*{box-sizing:border-box;margin:0;padding:0}
body{background:radial-gradient(circle at 50% -10%,#16263d 0%,var(--bg) 65%);color:var(--text);font:15px/1.5 system-ui,-apple-system,sans-serif;min-height:100vh}
a{color:var(--accent)}
header{padding:14px 20px;border-bottom:1px solid var(--line);display:flex;align-items:center;gap:12px}
header h1{font-size:1.05rem;font-weight:650}
.dim{color:#8a99b0;font-size:.8rem}
.dot{width:9px;height:9px;border-radius:50%;background:#445;display:inline-block}
.dot.on{background:var(--green);box-shadow:0 0 8px var(--green)}
.wrap{max-width:1040px;margin:0 auto;padding:1.2rem;display:flex;gap:1.2rem;align-items:flex-start}
main{flex:1;min-width:0}
.side{width:260px;flex:none}
@media(max-width:820px){.wrap{flex-direction:column}.side{width:100%}}
.banner{border-radius:12px;padding:1.1rem 1.2rem;margin-bottom:1.2rem;border:1px solid var(--line);background:var(--panel)}
.banner.alert{background:linear-gradient(180deg,#3a1416,#241016);border-color:#6e2630}
.banner.alert.warn{animation:pulse 1.4s infinite}
@keyframes pulse{0%,100%{box-shadow:0 0 0 0 rgba(255,90,90,.0)}50%{box-shadow:0 0 24px 0 rgba(255,90,90,.35)}}
.banner .ev{font-size:1.5rem;font-weight:700}
.banner.alert .ev{color:var(--red)}
.banner .meta{color:#b9c6d6;font-size:.85rem;margin-top:.35rem}
.banner .raw{margin-top:.6rem;padding:.5rem .6rem;background:#0b0f17;border:1px solid var(--line);border-radius:7px;font:12px/1.45 ui-monospace,SFMono-Regular,Menlo,monospace;color:#9fb0c4;word-break:break-all}
.banner .nwslink{margin-top:.7rem;font-size:.9rem;font-weight:600}
.banner .nws{margin-top:.7rem;padding:.7rem .8rem;background:rgba(0,0,0,.25);border:1px solid var(--line);border-radius:8px}
.banner .nws .nh{font-weight:650;color:#ffd9a8}
.banner .nws .na{color:#b9c6d6;font-size:.82rem;margin:.2rem 0 .5rem}
.banner .nws .nd{white-space:pre-wrap;font-size:.88rem;color:#dce6f1;max-height:280px;overflow:auto}
.banner .nws .ni{white-space:pre-wrap;font-size:.88rem;color:#ffd9a8;margin-top:.5rem}
.banner .ok{color:var(--green);font-size:1.1rem;font-weight:600}
.player{background:var(--panel);border:1px solid var(--line);border-radius:12px;padding:1rem 1.2rem;display:flex;align-items:center;gap:14px;margin-bottom:1.2rem;flex-wrap:wrap}
.player b{font-weight:650}
audio{height:38px}
.btn{background:#1d2837;color:var(--text);border:1px solid var(--line);border-radius:8px;padding:.5rem .8rem;font:inherit;font-size:.85rem;cursor:pointer}
.btn:hover{background:#243245}
.recent{background:var(--panel);border:1px solid var(--line);border-radius:12px;overflow:hidden}
.recent h2,.card h2{font-size:.72rem;color:#8a99b0;text-transform:uppercase;letter-spacing:.06em;padding:.6rem 1rem;border-bottom:1px solid var(--line)}
.r{padding:.55rem 1rem;border-bottom:1px solid var(--line);display:flex;justify-content:space-between;gap:1rem}
.r:last-child{border-bottom:0}.r .e{font-weight:600}.r time{color:#8a99b0;font-size:.8rem;white-space:nowrap}
.empty{color:#8a99b0;padding:1rem;text-align:center}
.card{background:var(--panel);border:1px solid var(--line);border-radius:12px;overflow:hidden}
.cty{display:flex;align-items:center;justify-content:space-between;gap:.6rem;padding:.55rem 1rem;border-bottom:1px solid var(--line)}
.cty:last-of-type{border-bottom:0}
.cty .cn{font-weight:600}.cty .cn .st{color:#8a99b0;font-weight:400;font-size:.8rem;margin-left:.25rem}
.pill{font-size:.7rem;color:var(--green);border:1px solid #2c5a3f;background:rgba(92,224,138,.08);border-radius:999px;padding:.12rem .5rem;white-space:nowrap}
.note{color:#8a99b0;font-size:.76rem;padding:.6rem 1rem;border-top:1px solid var(--line)}
.sw{position:relative;display:inline-block;width:40px;height:22px;flex:none}
.sw input{opacity:0;width:0;height:0}
.sw .track{position:absolute;inset:0;background:#2a3647;border-radius:999px;transition:.18s;cursor:pointer}
.sw .track:before{content:"";position:absolute;height:16px;width:16px;left:3px;top:3px;background:#cdd8e6;border-radius:50%;transition:.18s}
.sw input:checked+.track{background:var(--green)}
.sw input:checked+.track:before{transform:translateX(18px);background:#0b0f17}
</style></head><body>
<header><span class="dot" id="dot"></span><h1>NOAA Weather Radio</h1><span class="dim">162.550 MHz &middot; SAME alert monitor</span></header>
<div class="wrap">
<main>
<div class="banner" id="banner"><div class="ok">No active alerts</div><div class="meta">monitoring SAME &mdash; the banner turns red on a warning.</div></div>
<div class="player"><b>Live</b><audio controls preload="none" src="__PUBLIC__"></audio><span class="dim" style="flex:1"></span><button class="btn" id="testbtn">Test alert</button></div>
<div class="recent"><h2>Recent alerts</h2><div id="rows"><div class="empty">none yet</div></div></div>
</main>
<aside class="side">
<div class="card"><h2>Alert counties</h2><div id="counties"><div class="empty">loading&hellip;</div></div>
<div class="note">Cape Girardeau is always on. Toggle a neighbor to include its NWS SAME alerts &mdash; it stays on until you switch it off.</div></div>
</aside>
</div>
<script>
var $=function(i){return document.getElementById(i)};
function esc(s){return String(s).replace(/[&<>]/g,function(m){return{'&':'&amp;','<':'&lt;','>':'&gt;'}[m]})}
function fmtTs(t){if(!t)return'';var d=new Date(t*1000);return d.toLocaleString()}
function render(d){
 $('dot').classList.toggle('on',!!d.decoder);
 var b=$('banner'),a=d.active;
 if(a){b.className='banner alert'+(a.priority?' warn':'');
  var h='<div class="ev">'+esc(a.event)+'</div><div class="meta">'+(a.areas&&a.areas.length?'FIPS '+esc(a.areas.join(', '))+' &middot; ':'')+'issued '+fmtTs(a.ts)+(a.station?' &middot; '+esc(a.station):'')+'</div>';
  if(a.raw)h+='<div class="raw">'+esc(a.raw)+'</div>';
  if(a.nws_url)h+='<div class="nwslink"><a href="'+esc(a.nws_url)+'" target="_blank" rel="noopener">View on weather.gov &#8599;</a></div>';
  if(a.nws){var n=a.nws;h+='<div class="nws">'
   +(n.headline?'<div class="nh">'+esc(n.headline)+'</div>':'')
   +(n.areaDesc?'<div class="na">'+esc(n.areaDesc)+'</div>':'')
   +(n.description?'<div class="nd">'+esc(n.description)+'</div>':'')
   +(n.instruction?'<div class="ni"><b>Instructions:</b>\\n'+esc(n.instruction)+'</div>':'')
   +'</div>';}
  b.innerHTML=h;}
 else{b.className='banner';b.innerHTML='<div class="ok">No active alerts</div><div class="meta">monitoring SAME &mdash; the banner turns red on a warning.</div>';}
 var r=d.recent||[];
 $('rows').innerHTML=r.length?r.map(function(x){return '<div class="r"><span class="e">'+esc(x.event)+'</span><time>'+fmtTs(x.ts)+'</time></div>'}).join(''):'<div class="empty">none yet</div>';
}
function renderCounties(d){
 var el=$('counties'),cs=(d&&d.counties)||[];
 if(!cs.length){el.innerHTML='<div class="empty">none</div>';return;}
 el.innerHTML=cs.map(function(c){
  var sw=c.locked?'<span class="pill">always on</span>'
   :'<label class="sw"><input type="checkbox" data-fips="'+esc(c.fips)+'"'+(c.enabled?' checked':'')+'><span class="track"></span></label>';
  return '<div class="cty"><div class="cn"><a href="'+esc(c.url)+'" target="_blank" rel="noopener">'+esc(c.name)+'</a><span class="st">'+esc(c.st)+'</span></div>'+sw+'</div>';
 }).join('');
 Array.prototype.forEach.call(el.querySelectorAll('input[data-fips]'),function(inp){
  inp.addEventListener('change',function(){
   inp.disabled=true;
   fetch('/api/counties',{method:'POST',headers:{'Content-Type':'application/json'},
    body:JSON.stringify({fips:inp.getAttribute('data-fips'),enabled:inp.checked})})
    .then(function(r){return r.json()}).then(renderCounties).catch(function(){inp.disabled=false;});
  });
 });
}
function poll(){fetch('/api/alert',{cache:'no-store'}).then(function(r){return r.json()}).then(render).catch(function(){})}
function loadCounties(){fetch('/api/counties',{cache:'no-store'}).then(function(r){return r.json()}).then(renderCounties).catch(function(){})}
$('testbtn').addEventListener('click',function(){fetch('/api/test',{method:'POST'}).then(poll)});
poll();setInterval(poll,4000);loadCounties();
</script></body></html>"""


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def _json(self, code, obj):
        d = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(d)))
        # Public read-only JSON — allow the cross-origin embed
        # (weather.bobgardner.org) to poll /api/alert. Simple GET, no preflight.
        self.send_header("Access-Control-Allow-Origin", "*")
        self.end_headers()
        self.wfile.write(d)

    def do_GET(self):
        if self.path == "/" or self.path.startswith("/?"):
            body = PAGE.replace("__PUBLIC__", PUBLIC_URL).encode()
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        elif self.path == "/api/alert":
            with _LOCK:
                a = STATE["active"]
                if a and a.get("expires") and time.time() > a["expires"]:
                    STATE["active"] = None     # warning's valid-time has passed
                self._json(200, dict(STATE))
        elif self.path == "/api/counties":
            self._json(200, counties_payload())
        else:
            self._json(404, {"error": "not found"})

    def do_POST(self):
        length = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(length) if length else b""
        if self.path == "/api/counties":
            try:
                body = json.loads(raw or b"{}")
            except ValueError:
                body = {}
            f5 = str(body.get("fips", ""))[-5:]
            want = bool(body.get("enabled"))
            if f5 in BY_FIPS5 and f5 not in LOCKED:
                with _LOCK:
                    ACTIVE_FIPS.add(f5) if want else ACTIVE_FIPS.discard(f5)
                    save_active(ACTIVE_FIPS)
                log(f"county {f5} -> {'on' if want else 'off'}")
            self._json(200, counties_payload())
        elif self.path == "/api/test":
            now = int(time.time())
            handle_alert({"event_code": "RWT", "event": "Required Weekly Test (manual)",
                          "org": "WXR", "areas": ["029031"], "duration": "0015",
                          "issued": "", "station": "TEST", "priority": False,
                          "raw": "ZCZC-WXR-RWT-029031+0015-TEST-",
                          "ts": now, "expires": now + 30})  # short so the demo clears
            self._json(200, {"ok": True})
        else:
            self._json(404, {"error": "not found"})


def main():
    threading.Thread(target=decoder_loop, daemon=True, name="same-decoder").start()
    log(f"wx-alert on :{PORT} decode={DECODE_URL} webhook={'set' if HA_WEBHOOK_URL else 'none'} "
        f"counties={','.join(sorted(ACTIVE_FIPS))}")
    ThreadingHTTPServer(("0.0.0.0", PORT), Handler).serve_forever()


if __name__ == "__main__":
    main()
