#!/usr/bin/env python3
"""wx_alert.py — NOAA Weather Radio page + SAME/EAS alert decoder (wx.rg2.io).

Serves a weather page (player for the continuous /wx.mp3 + a live alert banner)
and decodes SAME (Specific Area Message Encoding) alerts off the same audio:

    ffmpeg -i <wx.mp3> -f s16le -ar 22050 -ac 1 - | multimon-ng -a EAS -t raw -

On a decoded SAME header it parses the event (TOR/SVR/FFW…), the FIPS areas and
the valid time, then RESPONDS: shows the banner, fires a configurable webhook
(Home Assistant — announce on house speakers / push), and logs it. Stdlib only.

Env: WX_PORT (8090), WX_DECODE_URL (internal mount to decode),
     WX_PUBLIC_URL (public mount for the page player), HA_WEBHOOK_URL (optional).
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
        return {
            "event_code": event,
            "event": EVENT_NAMES.get(event, event),
            "org": org, "areas": areas, "duration": duration,
            "issued": issued, "station": station,
            "priority": event in HIGH_PRIORITY,
            "raw": h, "ts": int(time.time()),
        }
    except (IndexError, ValueError):
        return {"event_code": "???", "event": "Unparsed SAME", "raw": h,
                "priority": False, "areas": [], "ts": int(time.time())}


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
                    if alert:
                        handle_alert(alert)
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
header{padding:14px 20px;border-bottom:1px solid var(--line);display:flex;align-items:center;gap:12px}
header h1{font-size:1.05rem;font-weight:650}
.dim{color:#8a99b0;font-size:.8rem}
.dot{width:9px;height:9px;border-radius:50%;background:#445;display:inline-block}
.dot.on{background:var(--green);box-shadow:0 0 8px var(--green)}
main{max-width:680px;margin:0 auto;padding:1.2rem}
.banner{border-radius:12px;padding:1.1rem 1.2rem;margin-bottom:1.2rem;border:1px solid var(--line);background:var(--panel)}
.banner.alert{background:linear-gradient(180deg,#3a1416,#241016);border-color:#6e2630}
.banner.alert.warn{animation:pulse 1.4s infinite}
@keyframes pulse{0%,100%{box-shadow:0 0 0 0 rgba(255,90,90,.0)}50%{box-shadow:0 0 24px 0 rgba(255,90,90,.35)}}
.banner .ev{font-size:1.5rem;font-weight:700}
.banner.alert .ev{color:var(--red)}
.banner .meta{color:#b9c6d6;font-size:.85rem;margin-top:.35rem}
.banner .ok{color:var(--green);font-size:1.1rem;font-weight:600}
.player{background:var(--panel);border:1px solid var(--line);border-radius:12px;padding:1rem 1.2rem;display:flex;align-items:center;gap:14px;margin-bottom:1.2rem;flex-wrap:wrap}
.player b{font-weight:650}
audio{height:38px}
.btn{background:#1d2837;color:var(--text);border:1px solid var(--line);border-radius:8px;padding:.5rem .8rem;font:inherit;font-size:.85rem;cursor:pointer}
.btn:hover{background:#243245}
.recent{background:var(--panel);border:1px solid var(--line);border-radius:12px;overflow:hidden}
.recent h2{font-size:.72rem;color:#8a99b0;text-transform:uppercase;letter-spacing:.06em;padding:.6rem 1rem;border-bottom:1px solid var(--line)}
.r{padding:.55rem 1rem;border-bottom:1px solid var(--line);display:flex;justify-content:space-between;gap:1rem}
.r:last-child{border-bottom:0}.r .e{font-weight:600}.r time{color:#8a99b0;font-size:.8rem;white-space:nowrap}
.empty{color:#8a99b0;padding:1rem;text-align:center}
</style></head><body>
<header><span class="dot" id="dot"></span><h1>NOAA Weather Radio</h1><span class="dim">162.550 MHz &middot; SAME alert monitor</span></header>
<main>
<div class="banner" id="banner"><div class="ok">No active alerts</div><div class="meta">monitoring SAME &mdash; the banner turns red on a warning.</div></div>
<div class="player"><b>Live</b><audio controls preload="none" src="__PUBLIC__"></audio><span class="dim" style="flex:1"></span><button class="btn" id="testbtn">Test alert</button></div>
<div class="recent"><h2>Recent alerts</h2><div id="rows"><div class="empty">none yet</div></div></div>
</main>
<script>
var $=function(i){return document.getElementById(i)};
function esc(s){return String(s).replace(/[&<>]/g,function(m){return{'&':'&amp;','<':'&lt;','>':'&gt;'}[m]})}
function fmtTs(t){if(!t)return'';var d=new Date(t*1000);return d.toLocaleString()}
function render(d){
 $('dot').classList.toggle('on',!!d.decoder);
 var b=$('banner'),a=d.active;
 if(a){b.className='banner alert'+(a.priority?' warn':'');
  b.innerHTML='<div class="ev">'+esc(a.event)+'</div><div class="meta">'+(a.areas&&a.areas.length?'FIPS '+esc(a.areas.join(', '))+' &middot; ':'')+'issued '+fmtTs(a.ts)+(a.station?' &middot; '+esc(a.station):'')+'</div>';}
 else{b.className='banner';b.innerHTML='<div class="ok">No active alerts</div><div class="meta">monitoring SAME &mdash; the banner turns red on a warning.</div>';}
 var r=d.recent||[];
 $('rows').innerHTML=r.length?r.map(function(x){return '<div class="r"><span class="e">'+esc(x.event)+'</span><time>'+fmtTs(x.ts)+'</time></div>'}).join(''):'<div class="empty">none yet</div>';
}
function poll(){fetch('/api/alert',{cache:'no-store'}).then(function(r){return r.json()}).then(render).catch(function(){})}
$('testbtn').addEventListener('click',function(){fetch('/api/test',{method:'POST'}).then(poll)});
poll();setInterval(poll,4000);
</script></body></html>"""


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def _json(self, code, obj):
        d = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(d)))
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
                self._json(200, dict(STATE))
        else:
            self._json(404, {"error": "not found"})

    def do_POST(self):
        length = int(self.headers.get("Content-Length") or 0)
        if length:
            self.rfile.read(length)
        if self.path == "/api/test":
            handle_alert({"event_code": "RWT", "event": "Required Weekly Test (manual)",
                          "org": "WXR", "areas": ["029031"], "duration": "0015",
                          "issued": "", "station": "TEST", "priority": False,
                          "raw": "ZCZC-WXR-RWT-029031+0015-TEST-", "ts": int(time.time())})
            self._json(200, {"ok": True})
        else:
            self._json(404, {"error": "not found"})


def main():
    threading.Thread(target=decoder_loop, daemon=True, name="same-decoder").start()
    log(f"wx-alert on :{PORT} decode={DECODE_URL} webhook={'set' if HA_WEBHOOK_URL else 'none'}")
    ThreadingHTTPServer(("0.0.0.0", PORT), Handler).serve_forever()


if __name__ == "__main__":
    main()
