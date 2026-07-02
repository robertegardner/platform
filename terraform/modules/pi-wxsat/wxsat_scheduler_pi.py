#!/usr/bin/env python3
"""wxsat_scheduler_pi.py — Pi-LOCAL Meteor capture scheduler (goes.srvr).

Store-and-forward variant: predicts passes (pyorbital via the shared
wxsat_predict, TLE fetched when the link is up / cached when it isn't) and
records each pass LOCALLY from the localhost rtl_tcp (wxsat-rtltcp.service).
No decode here — the rack's wxsat-sync pulls completed capture dirs (the ones
holding capture.done/capture.failed) and does SatDump + gallery + ntfy. This
is what makes Meteor immune to Garage-UDB link flaps: nothing in the capture
path leaves the Pi.

Env (systemd EnvironmentFile /etc/wxsat/wxsat.env): everything
wxsat_predict.load_config() reads, plus WXSAT_CAPTURES_DIR.
--capture-now [SECS] records immediately (bypasses schedule + DRY_RUN).
"""
import argparse
import json
import logging
import os
import signal
import subprocess
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, "/opt/wxsat-pi")
import wxsat_predict as predict  # noqa: E402

log = logging.getLogger("wxsat.sched.pi")

CAPTURES_DIR = Path(os.environ.get("WXSAT_CAPTURES_DIR", "/var/lib/wxsat/captures"))
STATUS_PATH = Path(os.environ.get("WXSAT_STATUS_PATH", "/run/wxsat/wxsat_status.json"))
CAPTURE_SCRIPT = "/opt/wxsat-pi/wxsat_capture_pi.sh"
TIMESYNC_MARKER = Path("/run/systemd/timesync/synchronized")


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


def do_capture(p, cfg):
    out_dir = CAPTURES_DIR / datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    out_dir.mkdir(parents=True, exist_ok=True)
    duration = max(60, int(p["los_unix"] - time.time()) + int(cfg["post_los_s"]))
    meta = dict(p)
    meta.update({"duration_s": duration, "samplerate": int(cfg["samplerate"]),
                 "freq_hz": int(cfg["freq_mhz"] * 1e6),
                 # Per-satellite symbol rate (predict catalog); env is the fallback.
                 "lrpt_pipeline": p.get("lrpt_pipeline") or cfg["lrpt_pipeline"]})
    tmp = out_dir / "passmeta.json.tmp"
    tmp.write_text(json.dumps(meta))
    os.replace(tmp, out_dir / "passmeta.json")
    env = dict(os.environ,
               WXSAT_OUT_DIR=str(out_dir), WXSAT_DURATION=str(duration),
               WXSAT_SAMPLERATE=str(cfg["samplerate"]),
               WXSAT_FREQ_HZ=str(int(cfg["freq_mhz"] * 1e6)),
               # Sky track for the live sidecar.
               WXSAT_AOS=str(int(p["aos_unix"])), WXSAT_LOS=str(int(p["los_unix"])),
               WXSAT_SAT=str(p.get("satellite") or ""),
               WXSAT_NORAD=str(p.get("norad") or ""))
    log.info("CAPTURE %s -> %s (%ss)", p["satellite"], out_dir, duration)
    write_status(cfg, "capturing", capturing=p)
    # Own process group so a backstop timeout can killpg the whole tree (the
    # same orphan-proofing the rack scheduler grew in db4b2e1).
    proc = subprocess.Popen([CAPTURE_SCRIPT], env=env, start_new_session=True)
    try:
        # Record-only: duration + recovery-ladder slack. No decode budget needed.
        proc.wait(timeout=duration + 300)
    except subprocess.TimeoutExpired:
        for sig in (signal.SIGTERM, signal.SIGKILL):
            try:
                os.killpg(proc.pid, sig)
            except ProcessLookupError:
                break
            time.sleep(5)
        proc.wait()
    # The capture script owns the marker; if it died markerless, fail it here
    # so the rack still sees (and reports) the pass.
    if not (out_dir / "capture.done").exists() and not (out_dir / "capture.failed").exists():
        (out_dir / "capture.failed").write_text(f"scheduler backstop (rc={proc.returncode})\n")
    log.info("capture finished rc=%s (%s)", proc.returncode,
             "done" if (out_dir / "capture.done").exists() else "FAILED")
    return proc.returncode


def handle_pass(p, cfg):
    if cfg["dry_run"]:
        log.info("dry run — would capture %s (max %.0f deg)", p["satellite"],
                 p.get("max_elev") or 0)
        return
    do_capture(p, cfg)


def wait_for_clock_sync(timeout_s=300, poll_s=2):
    """The Pi has no RTC — a pre-NTP clock mispredicts AOS. Wait for timesyncd
    (absence of the marker just times out and proceeds with a warning)."""
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
    if TIMESYNC_MARKER.parent.exists():
        wait_for_clock_sync()
    log.info("wxsat PI scheduler up (dry_run=%s, sats=%s, min_elev=%g, rtl_tcp=127.0.0.1:%s)",
             cfg["dry_run"], [s["name"] for s in cfg["satellites"]], cfg["min_elev"],
             os.environ.get("WXSAT_RTLTCP_PORT", "1234"))
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


def main():
    logging.basicConfig(level=logging.INFO,
                        format="%(asctime)s %(name)s %(levelname)s %(message)s")
    logging.getLogger("pyorbital").setLevel(logging.WARNING)
    ap = argparse.ArgumentParser(description="wxsat PI capture scheduler")
    ap.add_argument("--capture-now", nargs="?", type=int, const=90, default=None,
                    metavar="SECS", help="REAL local capture immediately for SECS "
                    "(bypasses schedule AND DRY_RUN) — tests rtl_tcp -> baseband")
    args = ap.parse_args()
    cfg = predict.load_config()
    cfg["samplerate"] = os.environ.get("WXSAT_SAMPLERATE", "250000")
    if args.capture_now is not None:
        now = int(time.time())
        sat = cfg["satellites"][0] if cfg["satellites"] else {"name": "TEST", "norad": 0}
        secs = max(30, args.capture_now)
        p = {"satellite": sat["name"], "norad": sat["norad"], "aos_unix": now,
             "lrpt_pipeline": sat.get("lrpt_pipeline"),
             "los_unix": now + secs,
             "aos_iso": datetime.now(timezone.utc).isoformat(),
             "los_iso": datetime.fromtimestamp(now + secs, timezone.utc).isoformat(),
             "max_elev": 0.0, "duration_min": round(secs / 60, 1)}
        sys.exit(do_capture(p, cfg))
    run(cfg)


if __name__ == "__main__":
    main()
