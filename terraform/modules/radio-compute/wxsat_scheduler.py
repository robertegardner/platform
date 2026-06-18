#!/usr/bin/env python3
"""wxsat_scheduler.py (RACK variant) — Meteor-M LRPT capture scheduler on .84.

Unlike the Pi scheduler this owns a DEDICATED dongle (the Nooelec on p24, served
over rtl_tcp), so there is NO radio to protect: no Icecast listener check, no
SDR stop/restart, no station notations. It simply predicts Meteor-M2 passes
(pyorbital, via the vendored wxsat_predict), and at each pass runs the rack
capture (record from p24's rtl_tcp -> SatDump decode on .84). All products +
the captures index land in WXSAT_DIR, which the radio app's /wxsat gallery
serves locally once WXSAT_UPSTREAM is unset (the gallery cutover).

Writes the SAME JSON contracts the gallery reads:
  WXSAT_DIR/captures.json        {"captures": [rec, ...]}
  /run/sdr-streams/wxsat_passes.json   (predict.write_passes)
  /run/sdr-streams/wxsat_status.json   {state, updated, dry_run, next_pass, ...}

DRY_RUN=1 predicts + records "would_capture" but never touches p24/SatDump
(the safe default until the dongle is stable on a powered hub); flip to 0 to
arm real captures.
"""
import argparse
import json
import logging
import os
import re
import subprocess
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, "/opt/wxsat")
import wxsat_predict as predict  # noqa: E402

log = logging.getLogger("wxsat.sched.rack")

WXSAT_DIR     = predict.WXSAT_DIR
CAPTURES_PATH = WXSAT_DIR / "captures.json"
STATUS_PATH   = Path("/run/sdr-streams/wxsat_status.json")
TIMESYNC_MARKER = Path("/run/systemd/timesync/synchronized")
CAPTURE_SCRIPT  = "/opt/wxsat/wxsat_capture_rack.sh"


# --- captures index (schema matches the radio app's /api/wxsat/captures) ----
def _slug(name):
    return re.sub(r"[^a-z0-9]+", "-", name.lower()).strip("-")


def _load_index():
    try:
        d = json.loads(CAPTURES_PATH.read_text())
        return d.get("captures", []) if isinstance(d, dict) else []
    except (FileNotFoundError, json.JSONDecodeError, OSError):
        return []


def _save_index(captures):
    WXSAT_DIR.mkdir(parents=True, exist_ok=True)
    tmp = CAPTURES_PATH.with_suffix(".json.tmp")
    tmp.write_text(json.dumps({"captures": captures}))
    os.replace(tmp, CAPTURES_PATH)


def record_outcome(p, outcome, reason=None, image=None, thumb=None, outdir=None):
    rec = {
        "id": f"{_slug(p['satellite'])}-{int(p['aos_unix'])}",
        "satellite": p["satellite"], "norad": p.get("norad"),
        "aos_unix": int(p["aos_unix"]), "los_unix": int(p["los_unix"]),
        "max_elev": p.get("max_elev"), "duration_min": p.get("duration_min"),
        "outcome": outcome, "notation": None, "reason": reason,
        "image": image, "thumb": thumb, "listeners": 0, "authorized": False,
        "outdir": outdir, "created": int(time.time()),
    }
    caps = [c for c in _load_index() if c.get("id") != rec["id"]]
    caps.append(rec)
    _save_index(caps)
    log.info("recorded %s for %s (AOS %s, max %.0f deg)%s", outcome, p["satellite"],
             p["aos_iso"], p.get("max_elev") or 0, f" — {reason}" if reason else "")
    return rec


def _best_product(out_dir):
    """Largest PNG in a SatDump output dir -> (image, thumb) relative to WXSAT_DIR."""
    try:
        pngs = sorted(out_dir.rglob("*.png"), key=lambda f: f.stat().st_size, reverse=True)
    except OSError:
        return None, None
    if not pngs:
        return None, None
    best = pngs[0].relative_to(WXSAT_DIR).as_posix()
    return best, best


# --- live status (gallery shows next pass / capturing) ----------------------
def write_status(cfg, state, next_pass=None, capturing=None):
    payload = {"state": state, "updated": int(time.time()), "dry_run": cfg["dry_run"],
               "next_pass": next_pass, "capturing_pass": capturing}
    try:
        STATUS_PATH.parent.mkdir(parents=True, exist_ok=True)
        tmp = STATUS_PATH.with_suffix(".json.tmp")
        tmp.write_text(json.dumps(payload))
        os.replace(tmp, STATUS_PATH)
    except OSError as e:
        log.warning("write_status failed: %s", e)


# --- capture ----------------------------------------------------------------
def do_capture(p, cfg):
    out_dir = WXSAT_DIR / datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    reldir = out_dir.name
    duration = max(60, int(p["los_unix"] - time.time()) + int(cfg["post_los_s"]))
    env = dict(os.environ,
               WXSAT_OUT_DIR=str(out_dir), WXSAT_DURATION=str(duration),
               WXSAT_SAMPLERATE=str(cfg["samplerate"]),
               WXSAT_FREQ_HZ=str(int(cfg["freq_mhz"] * 1e6)),
               LRPT_PIPELINE=cfg["lrpt_pipeline"],
               # Pass metadata for the live-telemetry sidecar's sky track.
               WXSAT_AOS=str(int(p["aos_unix"])), WXSAT_LOS=str(int(p["los_unix"])),
               WXSAT_SAT=str(p.get("satellite") or ""),
               WXSAT_NORAD=str(p.get("norad") or ""))
    log.info("CAPTURE %s -> %s (%ss)", p["satellite"], out_dir, duration)
    write_status(cfg, "capturing", capturing=p)
    try:
        # Generous decode budget: a ~16-min record + up to two full ~1.8 GB
        # SatDump pipelines (72k then 80k fallback) can take ~15 min on the LXC;
        # 600 s killed a valid pass mid-decode. 1800 s covers both pipelines.
        r = subprocess.run([CAPTURE_SCRIPT], env=env, capture_output=True,
                           text=True, timeout=duration + 1800)
    except subprocess.TimeoutExpired:
        return record_outcome(p, "failed", reason="capture timed out", outdir=reldir)
    if r.returncode != 0:
        tail = (r.stderr or r.stdout or "capture failed").strip().splitlines()[-1:] or ["capture failed"]
        return record_outcome(p, "failed",
                              reason=f"{tail[0][:180]} (see {reldir}/capture.log)", outdir=reldir)
    image, thumb = _best_product(out_dir)
    if not image:
        return record_outcome(p, "failed",
                              reason=f"no image decoded (see {reldir}/capture.log)", outdir=reldir)
    return record_outcome(p, "image", image=image, thumb=thumb or image, outdir=reldir)


def handle_pass(p, cfg):
    """No listener check — the dongle is dedicated, so every pass captures."""
    if cfg["dry_run"]:
        return record_outcome(p, "would_capture",
                              reason="dry run — dedicated dongle, would capture")
    return do_capture(p, cfg)


# --- clock-sync gate (Pi-less LXC still benefits; harmless if already synced) -
def wait_for_clock_sync(timeout_s=300, poll_s=2):
    if TIMESYNC_MARKER.exists():
        return True
    waited = 0
    while waited < timeout_s:
        time.sleep(poll_s)
        waited += poll_s
        if TIMESYNC_MARKER.exists():
            return True
    log.warning("clock-sync marker absent after %ds — proceeding", timeout_s)
    return False


def run(cfg):
    processed = set()
    # The clock-sync gate matters only where timesyncd runs (the Pi has no RTC).
    # The rack LXC inherits the host's correct clock and has no timesyncd, so
    # skip the wait when the timesync dir is absent — else we'd block 300s.
    if TIMESYNC_MARKER.parent.exists():
        wait_for_clock_sync()
    log.info("wxsat RACK scheduler up (dry_run=%s, sats=%s, min_elev=%g, rtl_tcp=%s:%s)",
             cfg["dry_run"], [s["name"] for s in cfg["satellites"]], cfg["min_elev"],
             os.environ.get("WXSAT_RTLTCP_HOST"), os.environ.get("WXSAT_RTLTCP_PORT"))
    while True:
        passes = predict.compute_passes(cfg)
        predict.write_passes(passes, cfg)
        now = time.time()
        due = [p for p in passes
               if (p["norad"], int(p["aos_unix"])) not in processed
               and p["aos_unix"] - cfg["aos_buffer_s"] <= now <= p["los_unix"]]
        if due:
            p = due[0]
            handle_pass(p, cfg)
            processed.add((p["norad"], int(p["aos_unix"])))
            time.sleep(max(5, p["los_unix"] + cfg["post_los_s"] - time.time()))
            continue
        upcoming = [p for p in passes
                    if (p["norad"], int(p["aos_unix"])) not in processed
                    and p["aos_unix"] - cfg["aos_buffer_s"] > now]
        if upcoming:
            nxt = min(upcoming, key=lambda p: p["aos_unix"])
            sleep_s = min(cfg["refresh_interval_s"],
                          max(5, nxt["aos_unix"] - cfg["aos_buffer_s"] - now))
            write_status(cfg, "scheduled", next_pass=nxt)
            log.info("next: %s AOS %s (max %.0f deg) — sleeping %.0fs", nxt["satellite"],
                     nxt["aos_iso"], nxt.get("max_elev") or 0, sleep_s)
        else:
            sleep_s = cfg["refresh_interval_s"]
            write_status(cfg, "idle")
            log.info("no passes >= %g deg in %gh — sleeping %.0fs",
                     cfg["min_elev"], cfg["predict_hours"], sleep_s)
        time.sleep(sleep_s)


def _synthetic_pass(cfg):
    now = int(time.time())
    sat = cfg["satellites"][0]["name"] if cfg["satellites"] else "METEOR-M2 4"
    norad = cfg["satellites"][0]["norad"] if cfg["satellites"] else 59051
    return {"satellite": sat, "norad": norad, "aos_unix": now, "los_unix": now + 600,
            "aos_iso": datetime.now(timezone.utc).isoformat(),
            "los_iso": datetime.fromtimestamp(now + 600, timezone.utc).isoformat(),
            "max_elev": 0.0, "duration_min": 10.0}


def main():
    logging.basicConfig(level=logging.INFO,
                        format="%(asctime)s %(name)s %(levelname)s %(message)s")
    logging.getLogger("pyorbital").setLevel(logging.WARNING)
    ap = argparse.ArgumentParser(description="wxsat RACK capture scheduler")
    ap.add_argument("--capture-now", nargs="?", type=int, const=90, default=None,
                    metavar="SECS", help="REAL capture immediately for SECS seconds "
                    "(bypasses the schedule AND DRY_RUN) — tests the rtl_tcp->SatDump chain")
    args = ap.parse_args()
    cfg = predict.load_config()
    # Rack samplerate default differs from the Pi's 2.048M (RTL Nooelec @ 1.024M).
    cfg["samplerate"] = os.environ.get("WXSAT_SAMPLERATE", "250000")

    if args.capture_now is not None:
        p = _synthetic_pass(cfg)
        p["los_unix"] = int(time.time()) + max(30, args.capture_now)
        print(json.dumps(do_capture(p, cfg), indent=2))
        return
    run(cfg)


if __name__ == "__main__":
    main()
