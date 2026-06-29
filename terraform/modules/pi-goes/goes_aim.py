#!/usr/bin/env python3
"""goes_aim.py — GOES dish-aiming tool (served on goes.srvr).

Two halves of aiming a dish at a geostationary GOES satellite:

  1. WHERE to point — the look angles (azimuth true+magnetic, elevation) from the
     station to the satellite. Geostationary, so this is a fixed target computed
     once from the station lat/lon and the satellite's orbital longitude.
  2. PEAKING — live signal feedback so you can fine-tune by hand. Reads SatDump's
     live HTTP API (the running `satdump live ... --http_server`) for SNR, the
     Viterbi BER, the lock flags and the Reed-Solomon error average, and shows a
     big meter + peak-hold + an optional audio tone that rises with SNR so you can
     peak the dish by ear without looking at the phone.

Stdlib only. Env: GOES_AIM_PORT (8091), GOES_AIM_LAT (37.336), GOES_AIM_LON
(-89.535), GOES_AIM_SAT_LON (-75.2, GOES-19/East), GOES_AIM_DECL (magnetic
declination east-positive deg, ~ -1.2 at Cape Girardeau), GOES_AIM_SAT_NAME
(GOES-19), SATDUMP_API (http://127.0.0.1:8080/api).
"""
import json
import math
import os
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT = int(os.environ.get("GOES_AIM_PORT", "8091"))
LAT = float(os.environ.get("GOES_AIM_LAT", "37.336"))
LON = float(os.environ.get("GOES_AIM_LON", "-89.535"))
SAT_LON = float(os.environ.get("GOES_AIM_SAT_LON", "-75.2"))
DECL = float(os.environ.get("GOES_AIM_DECL", "-1.2"))      # east-positive degrees
SAT_NAME = os.environ.get("GOES_AIM_SAT_NAME", "GOES-19")
SATDUMP_API = os.environ.get("SATDUMP_API", "http://127.0.0.1:8080/api")

R_EARTH = 6378.137          # km
R_GEO = 42164.0             # km (geostationary orbit radius)


def look_angles(lat_deg, lon_deg, sat_lon_deg):
    """Azimuth (deg true, clockwise from north) + elevation (deg) to a
    geostationary satellite, via the local ENU frame (unambiguous quadrants)."""
    slat, slon = math.radians(lat_deg), math.radians(lon_deg)
    # Station ECEF (spherical earth is plenty for dish pointing).
    sx = R_EARTH * math.cos(slat) * math.cos(slon)
    sy = R_EARTH * math.cos(slat) * math.sin(slon)
    sz = R_EARTH * math.sin(slat)
    # Satellite ECEF (equatorial, at sat_lon).
    tlon = math.radians(sat_lon_deg)
    tx = R_GEO * math.cos(tlon)
    ty = R_GEO * math.sin(tlon)
    tz = 0.0
    dx, dy, dz = tx - sx, ty - sy, tz - sz
    # Rotate the line-of-sight into the station's East/North/Up frame.
    east = -math.sin(slon) * dx + math.cos(slon) * dy
    north = (-math.sin(slat) * math.cos(slon) * dx
             - math.sin(slat) * math.sin(slon) * dy
             + math.cos(slat) * dz)
    up = (math.cos(slat) * math.cos(slon) * dx
          + math.cos(slat) * math.sin(slon) * dy
          + math.sin(slat) * dz)
    az = (math.degrees(math.atan2(east, north)) + 360.0) % 360.0
    el = math.degrees(math.atan2(up, math.hypot(east, north)))
    return az, el


AZ_TRUE, EL = look_angles(LAT, LON, SAT_LON)
AZ_MAG = (AZ_TRUE - DECL + 360.0) % 360.0     # magnetic bearing = true - declination


def compass(az):
    pts = ["N", "NNE", "NE", "ENE", "E", "ESE", "SE", "SSE",
           "S", "SSW", "SW", "WSW", "W", "WNW", "NW", "NNW"]
    return pts[int((az + 11.25) % 360 / 22.5)]


POINTING = {
    "satellite": SAT_NAME, "sat_lon": SAT_LON,
    "station": {"lat": LAT, "lon": LON},
    "az_true": round(AZ_TRUE, 1), "az_mag": round(AZ_MAG, 1),
    "az_compass": compass(AZ_TRUE), "elevation": round(EL, 1),
    "declination": DECL,
}


def read_satdump():
    """SatDump live metrics → a flat signal dict (best-effort)."""
    try:
        with urllib.request.urlopen(SATDUMP_API, timeout=3) as r:
            d = json.load(r)
    except Exception as e:  # noqa: BLE001
        return {"ok": False, "error": str(e)}
    dem = d.get("psk_demod", {}) or {}
    dec = d.get("ccsds_conv_concat_decoder", {}) or {}
    snr = dem.get("snr")
    return {
        "ok": True,
        "snr": round(snr, 2) if isinstance(snr, (int, float)) else None,
        "peak_snr": round(dem.get("peak_snr"), 2) if isinstance(dem.get("peak_snr"), (int, float)) else None,
        "freq": dem.get("freq"),
        "viterbi_ber": dec.get("viterbi_ber"),
        "viterbi_lock": bool(dec.get("viterbi_lock")),
        "deframer_lock": bool(dec.get("deframer_lock")),
        "rs_avg": dec.get("rs_avg"),
        "locked": bool(dec.get("deframer_lock")) and bool(dec.get("viterbi_lock")),
    }


PAGE = """<!doctype html><html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=1">
<title>GOES Dish Aim</title><style>
:root{--bg:#0a0e16;--panel:#141b27;--line:#243245;--text:#e6edf5;--dim:#8a99b0;--g:#5ce08a;--y:#ffb03a;--r:#ff5a5a;--accent:#4ea1ff}
*{box-sizing:border-box;margin:0;padding:0;-webkit-tap-highlight-color:transparent}
body{background:var(--bg);color:var(--text);font:16px/1.4 system-ui,-apple-system,sans-serif;padding:.8rem;max-width:560px;margin:0 auto}
h1{font-size:1rem;font-weight:650;margin-bottom:.6rem;display:flex;align-items:center;gap:.5rem}
.dot{width:10px;height:10px;border-radius:50%;background:#445}
.dot.lock{background:var(--g);box-shadow:0 0 10px var(--g)}
.card{background:var(--panel);border:1px solid var(--line);border-radius:12px;padding:.9rem 1rem;margin-bottom:.7rem}
.pt{display:flex;gap:.6rem;text-align:center}
.pt .b{flex:1;background:#0d1420;border:1px solid var(--line);border-radius:10px;padding:.5rem}
.pt .v{font-size:1.9rem;font-weight:700;line-height:1.1}
.pt .l{font-size:.68rem;color:var(--dim);text-transform:uppercase;letter-spacing:.05em}
.pt .s{font-size:.78rem;color:var(--accent);margin-top:.15rem}
.snrwrap{text-align:center;margin:.2rem 0 .5rem}
.snr{font-size:4.2rem;font-weight:800;line-height:1;font-variant-numeric:tabular-nums}
.snr small{font-size:1.1rem;color:var(--dim);font-weight:600}
.peak{color:var(--dim);font-size:.85rem;margin-top:.2rem}
.bar{height:26px;background:#0d1420;border:1px solid var(--line);border-radius:8px;overflow:hidden;margin:.5rem 0}
.bar>span{display:block;height:100%;width:0;background:linear-gradient(90deg,#3a6,#6e6,#fd6,#f96);transition:width .15s}
.grid{display:grid;grid-template-columns:1fr 1fr;gap:.5rem;margin-top:.5rem}
.kv{background:#0d1420;border:1px solid var(--line);border-radius:8px;padding:.45rem .6rem}
.kv .k{font-size:.66rem;color:var(--dim);text-transform:uppercase;letter-spacing:.04em}
.kv .vv{font-size:1.1rem;font-weight:650;font-variant-numeric:tabular-nums}
.badge{display:inline-block;font-size:.72rem;font-weight:700;padding:.15rem .5rem;border-radius:999px;border:1px solid var(--line);color:var(--dim)}
.badge.on{color:#08111d;background:var(--g);border-color:var(--g)}
.row{display:flex;gap:.4rem;flex-wrap:wrap;align-items:center;margin-top:.4rem}
button{background:#1d2837;color:var(--text);border:1px solid var(--line);border-radius:9px;padding:.55rem .9rem;font:inherit;font-size:.9rem;font-weight:600;cursor:pointer}
button.on{background:var(--accent);color:#08111d;border-color:var(--accent)}
.hint{color:var(--dim);font-size:.78rem;margin-top:.5rem}
</style></head><body>
<h1><span class="dot" id="dot"></span>GOES Dish Aim &middot; <span id="sat"></span></h1>
<div class="card">
  <div class="pt">
    <div class="b"><div class="v" id="az"></div><div class="l">Azimuth (mag)</div><div class="s" id="azt"></div></div>
    <div class="b"><div class="v" id="el"></div><div class="l">Elevation</div><div class="s" id="azc"></div></div>
  </div>
  <div class="hint" id="ptn"></div>
</div>
<div class="card">
  <div class="snrwrap"><div class="snr" id="snr">--<small>dB SNR</small></div>
  <div class="peak">peak (since reset): <b id="pk">--</b> dB</div></div>
  <div class="bar"><span id="snrbar"></span></div>
  <div class="row">
    <span class="badge" id="lk1">DEFRAMER</span>
    <span class="badge" id="lk2">VITERBI</span>
    <span class="badge" id="lk3" style="margin-left:auto">DECODING</span>
  </div>
  <div class="grid">
    <div class="kv"><div class="k">Viterbi BER</div><div class="vv" id="ber">--</div></div>
    <div class="kv"><div class="k">RS errors (avg)</div><div class="vv" id="rs">--</div></div>
  </div>
  <div class="row"><button id="tone">🔊 Peak tone: off</button><button id="rst">Reset peak</button></div>
  <div class="hint">Aim to the az/el, then nudge to <b>maximize SNR</b> &mdash; the tone pitch rises with SNR. Badges go green when it locks &amp; decodes.</div>
</div>
<script>
var $=function(i){return document.getElementById(i)};var peak=0, ctx=null, osc=null, gain=null, toneOn=false;
function setBadge(el,on){el.className='badge'+(on?' on':'')}
function render(d){
  var p=d.pointing, s=d.signal||{};
  $('sat').textContent=p.satellite;
  $('az').textContent=p.az_mag.toFixed(0)+'°';
  $('azt').textContent='true '+p.az_true.toFixed(0)+'°';
  $('azc').textContent=p.az_compass;
  $('el').textContent=p.elevation.toFixed(0)+'°';
  $('ptn').textContent='Point '+p.az_compass+' — magnetic compass '+p.az_mag.toFixed(0)+'° (true '+p.az_true.toFixed(0)+'°, decl '+p.declination+'°), tilt up '+p.elevation.toFixed(0)+'°.';
  var ok=s.ok, snr=(s.snr==null?null:s.snr);
  $('dot').className='dot'+(s.locked?' lock':'');
  if(snr==null){$('snr').innerHTML='--<small>dB SNR</small>';}
  else{
    $('snr').innerHTML=snr.toFixed(1)+'<small>dB SNR</small>';
    if(snr>peak){peak=snr;}
    $('pk').textContent=peak.toFixed(1);
    var pct=Math.max(0,Math.min(100,(snr/12)*100));   // ~12 dB full scale
    $('snrbar').style.width=pct+'%';
    if(toneOn&&osc){osc.frequency.value=180+Math.max(0,snr)*90;}  // pitch rises w/ SNR
  }
  $('ber').textContent=(s.viterbi_ber==null?'--':Number(s.viterbi_ber).toFixed(3));
  $('rs').textContent=(s.rs_avg==null?'--':s.rs_avg);
  setBadge($('lk1'),s.deframer_lock); setBadge($('lk2'),s.viterbi_lock); setBadge($('lk3'),s.locked);
}
function poll(){fetch('/api/aim',{cache:'no-store'}).then(function(r){return r.json()}).then(render).catch(function(){})}
$('rst').onclick=function(){peak=0;};
$('tone').onclick=function(){
  if(!toneOn){
    ctx=ctx||new (window.AudioContext||window.webkitAudioContext)();
    osc=ctx.createOscillator();gain=ctx.createGain();gain.gain.value=0.06;
    osc.type='sine';osc.frequency.value=300;osc.connect(gain);gain.connect(ctx.destination);osc.start();
    toneOn=true;this.classList.add('on');this.textContent='🔊 Peak tone: on';
  }else{try{osc.stop();}catch(e){}osc=null;toneOn=false;this.classList.remove('on');this.textContent='🔊 Peak tone: off';}
};
poll();setInterval(poll,700);
</script></body></html>"""


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def do_GET(self):
        if self.path == "/" or self.path.startswith("/?"):
            body = PAGE.encode()
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        elif self.path.startswith("/api/aim"):
            out = json.dumps({"pointing": POINTING, "signal": read_satdump()}).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(out)))
            self.send_header("Access-Control-Allow-Origin", "*")
            self.end_headers()
            self.wfile.write(out)
        else:
            self.send_response(404)
            self.end_headers()


def main():
    print(f"goes-aim on :{PORT} | {SAT_NAME} @ {SAT_LON} | "
          f"AZ true {AZ_TRUE:.1f} / mag {AZ_MAG:.1f} ({compass(AZ_TRUE)}), EL {EL:.1f} | "
          f"satdump={SATDUMP_API}", flush=True)
    ThreadingHTTPServer(("0.0.0.0", PORT), Handler).serve_forever()


if __name__ == "__main__":
    main()
