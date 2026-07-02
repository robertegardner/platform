#!/usr/bin/env python3
"""wxsat_sync.py — rack side of the Pi-local Meteor pipeline (.84).

One tick (systemd timer, ~5 min): refresh the pass forecast for the gallery,
pull completed capture dirs from the Pi (goes.srvr), decode any that lack a
decode.done marker (decode-only wxsat_capture_rack.sh), index + ntfy via the
same record_outcome the old streaming scheduler used. Idempotent: markers gate
everything; reruns are no-ops. The Pi being unreachable just means this tick
does prediction only — the Pi keeps capturing regardless (that is the point).
"""
import json
import logging
import os
import signal
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, "/opt/wxsat")
import wxsat_predict as predict     # noqa: E402
import wxsat_scheduler as sched     # noqa: E402  (record_outcome/_best_product/write_status)

log = logging.getLogger("wxsat.sync")

PI_HOST = os.environ.get("WXSAT_PI_HOST", "goes.srvr")
PI_USER = os.environ.get("WXSAT_PI_USER", "rgardner")
PI_CAPTURES = os.environ.get("WXSAT_PI_CAPTURES", "/var/lib/wxsat/captures")
SSH_KEY = os.environ.get("WXSAT_SYNC_KEY", "/var/lib/sdr-streams/wxsat/.ssh/id_wxsat")
SSH_OPTS = ["-i", SSH_KEY, "-o", "BatchMode=yes", "-o", "ConnectTimeout=10",
            "-o", "StrictHostKeyChecking=accept-new"]
WXSAT_DIR = predict.WXSAT_DIR
CAPTURE_SCRIPT = "/opt/wxsat/wxsat_capture_rack.sh"


def _ssh(cmd, timeout=30):
    return subprocess.run(["ssh", *SSH_OPTS, f"{PI_USER}@{PI_HOST}", cmd],
                          capture_output=True, text=True, timeout=timeout)


def list_remote_complete():
    """Names of Pi capture dirs holding a completion marker (None = unreachable)."""
    r = _ssh(f"find {PI_CAPTURES} -mindepth 2 -maxdepth 2 "
             r"\( -name capture.done -o -name capture.failed \) -printf '%h\n'")
    if r.returncode != 0:
        log.info("Pi unreachable (%s) — prediction-only tick", r.stderr.strip()[:120])
        return None
    return sorted({Path(line).name for line in r.stdout.splitlines() if line.strip()})


def pull(name):
    dest = WXSAT_DIR / name
    r = subprocess.run(
        ["rsync", "-az", "--timeout=120",
         "-e", "ssh " + " ".join(SSH_OPTS),
         f"{PI_USER}@{PI_HOST}:{PI_CAPTURES}/{name}/", f"{dest}/"],
        capture_output=True, text=True, timeout=1800)
    if r.returncode != 0:
        log.warning("rsync %s failed: %s", name, r.stderr.strip()[:200])
        return None
    return dest


def load_meta(d):
    try:
        return json.loads((d / "passmeta.json").read_text())
    except (FileNotFoundError, json.JSONDecodeError, OSError):
        # Old/foreign dir — synthesize enough for record_outcome.
        ts = int(time.time())
        return {"satellite": "METEOR-M2 ?", "norad": 0, "aos_unix": ts,
                "los_unix": ts, "max_elev": None, "duration_min": None,
                "aos_iso": "?", "samplerate": 250000,
                "lrpt_pipeline": "meteor_m2-x_lrpt"}


def decode(d, meta):
    env = dict(os.environ,
               WXSAT_DECODE_ONLY="1",
               WXSAT_OUT_DIR=str(d),
               WXSAT_DURATION=str(meta.get("duration_s", 900)),
               WXSAT_SAMPLERATE=str(meta.get("samplerate", 250000)),
               LRPT_PIPELINE=meta.get("lrpt_pipeline", "meteor_m2-x_lrpt"))
    # start_new_session + killpg backstop: same orphan-proofing as the old
    # scheduler (SatDump grinds forever on a no-lock baseband, db4b2e1).
    proc = subprocess.Popen([CAPTURE_SCRIPT], env=env, stdout=subprocess.PIPE,
                            stderr=subprocess.PIPE, text=True, start_new_session=True)
    try:
        out, err = proc.communicate(timeout=2100)
        return proc.returncode, out, err
    except subprocess.TimeoutExpired:
        for sig in (signal.SIGTERM, signal.SIGKILL):
            try:
                os.killpg(proc.pid, sig)
            except ProcessLookupError:
                break
            time.sleep(5)
        proc.wait()
        return 124, "", "decode backstop timeout"


def process(d):
    meta = load_meta(d)
    if (d / "capture.failed").exists():
        reason = (d / "capture.failed").read_text().strip()[:180]
        sched.record_outcome(meta, "failed", reason=f"Pi capture: {reason}", outdir=d.name)
    else:
        rc, out, err = decode(d, meta)
        image, thumb = sched._best_product(d)
        if image:
            sched.record_outcome(meta, "image", image=image, thumb=thumb or image,
                                 outdir=d.name)
        else:
            tail = (err or out or "no image").strip().splitlines()[-1:] or ["no image"]
            sched.record_outcome(meta, "failed",
                                 reason=f"{tail[0][:160]} (see {d.name}/capture.log)",
                                 outdir=d.name)
    (d / "decode.done").touch()


def main():
    logging.basicConfig(level=logging.INFO,
                        format="%(asctime)s %(name)s %(levelname)s %(message)s")
    logging.getLogger("pyorbital").setLevel(logging.WARNING)
    cfg = predict.load_config()
    # Gallery forecast (the old streaming scheduler used to own this).
    passes = []
    try:
        passes = predict.compute_passes(cfg)
        predict.write_passes(passes, cfg)
    except Exception as e:
        log.warning("prediction failed: %s", e)
    names = list_remote_complete()
    if names is None:
        # Pi unreachable: the live relay can't mirror the Pi's authoritative
        # status, so fall back to our own forecast (never leaves a stale
        # "capturing" on the gallery through an outage).
        try:
            upcoming = [p for p in passes if p["aos_unix"] > time.time()]
            sched.write_status(cfg, "scheduled" if upcoming else "idle",
                               next_pass=min(upcoming, key=lambda p: p["aos_unix"])
                               if upcoming else None)
        except Exception as e:
            log.warning("fallback status failed: %s", e)
        return
    todo = [n for n in names if not (WXSAT_DIR / n / "decode.done").exists()]
    if not todo:
        log.info("in sync (%d remote captures, none new)", len(names))
        return
    for name in todo:
        d = pull(name)
        if d is None:
            continue
        log.info("processing %s", name)
        process(d)


if __name__ == "__main__":
    main()
