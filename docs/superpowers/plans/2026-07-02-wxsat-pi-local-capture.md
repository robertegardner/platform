# wxsat Pi-Local Capture Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Meteor LRPT capture runs locally on goes.srvr (immune to Garage-UDB
link flaps); the rack pulls completed captures, decodes, indexes, notifies, and
relays the Pi's live-pass telemetry so the existing gallery/UI is unchanged.

**Architecture:** Pi-side scheduler (reusing `wxsat_predict.py`) records CU8
from localhost rtl_tcp into `/var/lib/wxsat/captures/<ts>Z/` with a
`capture.done`/`capture.failed` marker and a dongle-recovery ladder; a tiny
HTTP server exposes live telemetry. Rack-side, the streaming scheduler is
replaced by a 5-min `wxsat-sync` timer (rsync pull → decode-only
`wxsat_capture_rack.sh` → `record_outcome` → ntfy) plus a `wxsat-live-relay`
that mirrors the Pi's live JSON into `/run/sdr-streams/wxsat_live.json`.

**Tech Stack:** bash + python3 (stdlib + pyorbital/requests/numpy), systemd,
terraform remote-exec provisioners.

**Spec:** `docs/superpowers/specs/2026-07-02-wxsat-pi-local-capture-design.md`

**Spec deviations (approved rationale):**
1. TLE push from the rack is DROPPED — `wxsat_predict.py` already fetches from
   `tle.ivanstanojevic.me` (celestrak is not involved; the `/etc/hosts`
   blackhole only affects SatDump) and falls back to its cache, so the Pi
   predicts autonomously and degrades gracefully offline.
2. Pass metadata file is **`passmeta.json`**, not `pass.json` — `wxsat_live.py`
   already writes a `pass.json` replay snapshot into the capture dir.
3. Live view is relayed by a rack daemon (`wxsat-live-relay`) writing the SAME
   `/run/sdr-streams/wxsat_live.json` the tuner already reads (staleness >8 s ⇒
   `{live:false}`), so the radio repo needs NO changes.

## Global Constraints

- Pi paths: code `/opt/wxsat-pi/`, data `/var/lib/wxsat/{captures,tle,http}`,
  runtime `/run/wxsat/`, env `/etc/wxsat/wxsat.env` (keep-if-absent),
  HTTP :8078. Existing `/etc/wxsat/rtltcp.env` + `wxsat-rtltcp.service` are
  kept as-is.
- Rack paths unchanged: `/opt/wxsat/`, `/var/lib/sdr-streams/wxsat/`,
  `/etc/radio-compute/wxsat.env`.
- Meteor dongle = Nooelec SMArTee XTR **serial 74111838** (E4000). GOES dongle
  = 47360874 — NEVER touched by any wxsat code path.
- All provisioner edits re-run safe (keep-if-absent envs, overwrite code,
  `systemctl enable` + `restart`, never `enable --now`).
- `%{ }`/`${ }` are Terraform template syntax in `.tpl` files — every literal
  shell `${VAR}` inside a `.tpl` must be `$${VAR}`. Files embedded via
  `templatefile()` vars (`file("${path.module}/...")`) are exempt (inserted
  verbatim inside quoted heredocs).
- Deploy cadence: Pi via `terraform apply -target=module.pi_wxsat` (from
  thebeast as deploy); rack `.84` via manual staging (precedent: 2026-06-18) —
  staged content MUST equal provisioner content.

---

### Task 1: Parameterize shared modules + registry truth

**Files:**
- Modify: `terraform/modules/radio-compute/wxsat_predict.py:32-34`
- Modify: `terraform/modules/radio-compute/wxsat_live.py:32-33`
- Modify: `terraform/registry/devices.json:93-97` (serial + comment)

**Interfaces:**
- Produces: `wxsat_predict` honoring env `WXSAT_DIR` (data root; TLE cache at
  `$WXSAT_DIR/tle`) and `WXSAT_PASSES_PATH`; `wxsat_live` honoring env
  `WXSAT_LIVE_PATH` and `WXSAT_TLE_DIR`. Defaults unchanged (rack behavior
  identical with no env set).

- [ ] **Step 1: Patch `wxsat_predict.py` paths**

Replace lines 32–34:

```python
WXSAT_DIR  = Path(os.environ.get("WXSAT_DIR", "/var/lib/sdr-streams/wxsat"))
TLE_DIR    = WXSAT_DIR / "tle"
PASSES_PATH = Path(os.environ.get("WXSAT_PASSES_PATH",
                                  "/run/sdr-streams/wxsat_passes.json"))
```

- [ ] **Step 2: Patch `wxsat_live.py` paths**

Replace lines 32–33 (`LIVE_PATH = ...` / `TLE_DIR = ...`):

```python
LIVE_PATH = Path(os.environ.get("WXSAT_LIVE_PATH",
                                "/run/sdr-streams/wxsat_live.json"))
TLE_DIR = Path(os.environ.get("WXSAT_TLE_DIR", "/var/lib/sdr-streams/wxsat/tle"))
```

- [ ] **Step 3: Registry — Meteor dongle is now the XTR**

In `terraform/registry/devices.json` set `"serial": "74111838"` for
`nooelec-wx` and rewrite the `_comment` first sentence to: *"Nooelec SMArTee
XTR v5ee (RTL2838/E4000, serial 74111838 — replaced the flaky NESDR SMArt v5
22012952 on 2026-07-01) on the GOES Pi goes.srvr ..."* (rest of comment kept).
Note: gain is AGC now (E4000 has no simple linear gain; live wxsat.env has
`WXSAT_GAIN_TENTHS=` empty).

- [ ] **Step 4: Verify**

Run:
`python3 -m py_compile terraform/modules/radio-compute/wxsat_predict.py terraform/modules/radio-compute/wxsat_live.py && python3 -c "import json;json.load(open('terraform/registry/devices.json'))" && WXSAT_DIR=/tmp/x python3 -c "import sys;sys.path.insert(0,'terraform/modules/radio-compute');import wxsat_predict as p;assert str(p.TLE_DIR)=='/tmp/x/tle';print('OK')"`
Expected: `OK`

- [ ] **Step 5: Commit** — `git add -A && git commit -m "wxsat: env-parameterize predict/live paths; registry serial -> XTR 74111838"`

---

### Task 2: Pi scheduler (`wxsat_scheduler_pi.py`)

**Files:**
- Create: `terraform/modules/pi-wxsat/wxsat_scheduler_pi.py`

**Interfaces:**
- Consumes: `wxsat_predict.load_config()/compute_passes()/write_passes()`
  (Task 1 env-aware), `/opt/wxsat-pi/wxsat_capture_pi.sh` (Task 3 contract).
- Produces: capture dirs `$WXSAT_CAPTURES_DIR/<UTCts>Z/` containing
  `passmeta.json` `{satellite, norad, aos_unix, los_unix, max_elev,
  duration_min, aos_iso, los_iso, source, duration_s, samplerate, freq_hz,
  lrpt_pipeline}`, plus (from the capture script) `baseband.cu8`,
  `capture.log`, `pass.json` (live snapshot), and exactly one of
  `capture.done` / `capture.failed`. Status JSON at
  `/run/wxsat/wxsat_status.json` (same schema as the rack's).

- [ ] **Step 1: Write the file**

```python
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
                 "lrpt_pipeline": cfg["lrpt_pipeline"]})
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
    (or chrony absence just times out and proceeds with a warning)."""
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
        p = {"satellite": sat["name"], "norad": sat["norad"], "aos_unix": now,
             "los_unix": now + max(30, args.capture_now),
             "aos_iso": datetime.now(timezone.utc).isoformat(),
             "los_iso": datetime.fromtimestamp(now + max(30, args.capture_now),
                                               timezone.utc).isoformat(),
             "max_elev": 0.0, "duration_min": round(max(30, args.capture_now) / 60, 1)}
        sys.exit(do_capture(p, cfg))
    run(cfg)


if __name__ == "__main__":
    main()
```

- [ ] **Step 2: Verify** — `python3 -m py_compile terraform/modules/pi-wxsat/wxsat_scheduler_pi.py` → silent success.

- [ ] **Step 3: Commit** — `git commit -m "feat(pi-wxsat): Pi-local Meteor capture scheduler"`

---

### Task 3: Pi capture script (`wxsat_capture_pi.sh`) with recovery ladder

**Files:**
- Create: `terraform/modules/pi-wxsat/wxsat_capture_pi.sh`

**Interfaces:**
- Consumes: env from the scheduler (`WXSAT_OUT_DIR WXSAT_DURATION
  WXSAT_SAMPLERATE WXSAT_FREQ_HZ WXSAT_AOS WXSAT_LOS WXSAT_SAT WXSAT_NORAD`)
  and from wxsat.env (`WXSAT_GAIN_TENTHS WXSAT_RTLTCP_PORT WXSAT_MIN_FREE_GB`);
  `/etc/wxsat/rtltcp.env` for `WXSAT_SERIAL` (usbreset target);
  `/opt/wxsat-pi/wxsat_record_rtltcp.py` (rc 0 ok / 11 source fault /
  12 short); `/opt/wxsat-pi/wxsat_live.py` (Task 1 env-aware).
- Produces: `$WXSAT_OUT_DIR/{baseband.cu8, capture.log, capture.done |
  capture.failed}` (+ `pass.json` from the sidecar). Exit 0 iff capture.done.

- [ ] **Step 1: Write the file**

```bash
#!/bin/bash
# wxsat_capture_pi.sh — record ONE Meteor pass locally on goes.srvr from the
# localhost rtl_tcp (wxsat-rtltcp.service). RECORD-ONLY: no SatDump here — the
# rack's wxsat-sync pulls this dir (gated on capture.done/capture.failed) and
# decodes. Store-and-forward is the whole point: nothing below needs the LAN.
#
# Recovery ladder (both outdoor dongles have wedged with USB error -71):
#   attempt 1 -> bounce wxsat-rtltcp -> attempt 2 -> usbreset the Meteor dongle
#   (STRICTLY by WXSAT_SERIAL; never the GOES SMArTee) + bounce -> attempt 3.
# Each attempt records to its own file; the largest wins (a partial first
# attempt beats a dead retry).
#
# Exit: 0 recorded (capture.done written); 12 nothing recorded (capture.failed).
set -uo pipefail

OUT="${WXSAT_OUT_DIR:?WXSAT_OUT_DIR required}"
DUR="${WXSAT_DURATION:?WXSAT_DURATION required}"
MIN_FREE_GB="${WXSAT_MIN_FREE_GB:-4}"
SAMPLERATE="${WXSAT_SAMPLERATE:-250000}"
CAPTURES_ROOT="$(dirname "$OUT")"
IQ="$OUT/baseband.cu8"

mkdir -p "$OUT"
LOG="$OUT/capture.log"
exec > >(tee -a "$LOG") 2>&1
echo "wxsat-pi: capture starting $(date -u +%Y-%m-%dT%H:%M:%SZ) (${DUR}s @ ${SAMPLERATE})"

# Local rtl_tcp always — this script must not depend on any remote host.
export WXSAT_RTLTCP_HOST=127.0.0.1
export WXSAT_RTLTCP_PORT="${WXSAT_RTLTCP_PORT:-1234}"
# Live sidecar + predictor paths (Pi layout).
export WXSAT_LIVE_PATH=/run/wxsat/wxsat_live.json
export WXSAT_TLE_DIR=/var/lib/wxsat/tle

free_gb() { df -BG --output=avail "$OUT" 2>/dev/null | tail -1 | tr -dc '0-9'; }

mark_failed() { echo "$1" > "$OUT/capture.failed"; echo "wxsat-pi: FAILED — $1" >&2; }

cleanup() { [[ -n "${LIVE_PID:-}" ]] && kill "$LIVE_PID" 2>/dev/null; return 0; }
trap cleanup EXIT INT TERM

# Live telemetry sidecar (spectrum/level + sky track for /api/wxsat/live via
# the rack relay). Best-effort; read-only on the IQ.
mkdir -p /run/wxsat
if [ -f /opt/wxsat-pi/wxsat_live.py ]; then
  python3 /opt/wxsat-pi/wxsat_live.py &
  LIVE_PID=$!
fi

# Reclaim SD space: drop the oldest retained basebands first (markers/logs and
# the rack already has anything old enough to be a reclaim candidate).
need_gb=$(( (DUR * SAMPLERATE * 2 / 1000000000) + MIN_FREE_GB + 1 ))
while [[ "$(free_gb)" =~ ^[0-9]+$ && "$(free_gb)" -lt "$need_gb" ]]; do
  oldest="$(ls -1tr "$CAPTURES_ROOT"/*/baseband.cu8 2>/dev/null | grep -vF -- "$IQ" | head -1)"
  [[ -z "$oldest" ]] && { echo "wxsat-pi: low disk ($(free_gb)G < ${need_gb}G), nothing to reclaim" >&2; break; }
  echo "wxsat-pi: low disk — reclaiming $oldest" >&2
  rm -f "$oldest"
done

# Resolve the Meteor dongle's bus/dev for usbreset — by serial ONLY. Refuses to
# return anything if the serial isn't found (never guess: the GOES dongle and
# any future sticks must be untouchable).
meteor_busdev() {
  local serial="$1" d
  for d in /sys/bus/usb/devices/*/serial; do
    if [ "$(cat "$d" 2>/dev/null)" = "$serial" ]; then
      d="${d%/serial}"
      printf '%03d/%03d\n' "$(cat "$d/busnum")" "$(cat "$d/devnum")"
      return 0
    fi
  done
  return 1
}

attempt_record() {  # $1 = attempt number, $2 = seconds
  local f="$OUT/bb.$1.cu8"
  python3 /opt/wxsat-pi/wxsat_record_rtltcp.py "$f" "$2"
  local rc=$?
  echo "wxsat-pi: attempt $1 rc=$rc size=$(stat -c%s "$f" 2>/dev/null || echo 0)"
  return $rc
}

deadline=$(( $(date +%s) + DUR ))
attempt=1
while :; do
  remaining=$(( deadline - $(date +%s) ))
  [[ $remaining -lt 20 ]] && break
  attempt_record "$attempt" "$remaining"
  rc=$?
  # rc 0 = full record; rc 12 = short-but-usable (pass ended / stall at tail).
  [[ $rc -eq 0 || $rc -eq 12 ]] && break
  [[ $attempt -ge 3 ]] && break
  echo "wxsat-pi: recovery ladder step $attempt (rc=$rc)"
  if [[ $attempt -eq 1 ]]; then
    sudo systemctl restart wxsat-rtltcp.service
  else
    WXSAT_SERIAL=""
    [ -f /etc/wxsat/rtltcp.env ] && . /etc/wxsat/rtltcp.env
    if [[ -n "$WXSAT_SERIAL" ]] && busdev="$(meteor_busdev "$WXSAT_SERIAL")"; then
      echo "wxsat-pi: usbreset $busdev (serial $WXSAT_SERIAL)"
      sudo systemctl stop wxsat-rtltcp.service
      sudo usbreset "$busdev" || echo "wxsat-pi: usbreset failed" >&2
      sleep 3
      sudo systemctl start wxsat-rtltcp.service
    else
      echo "wxsat-pi: cannot resolve Meteor dongle by serial — skipping usbreset" >&2
      sudo systemctl restart wxsat-rtltcp.service
    fi
  fi
  sleep 8
  attempt=$(( attempt + 1 ))
done

# Largest attempt wins.
best="$(ls -S "$OUT"/bb.*.cu8 2>/dev/null | head -1)"
if [[ -n "$best" && -s "$best" ]]; then
  mv -f "$best" "$IQ"
fi
rm -f "$OUT"/bb.*.cu8

if [[ -s "$IQ" ]]; then
  size=$(stat -c%s "$IQ")
  # Below ~5 s of samples there is nothing decodable — call it failed.
  if [[ $size -lt $(( SAMPLERATE * 2 * 5 )) ]]; then
    mark_failed "only ${size}B of IQ recorded (see capture.log)"
    exit 12
  fi
  echo "recorded $(du -h "$IQ" | cut -f1) $(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$OUT/capture.done"
  echo "wxsat-pi: capture complete -> $IQ"
  exit 0
fi
mark_failed "no IQ recorded after ${attempt} attempt(s) (see capture.log)"
exit 12
```

- [ ] **Step 2: Verify** — `bash -n terraform/modules/pi-wxsat/wxsat_capture_pi.sh && shellcheck -S error terraform/modules/pi-wxsat/wxsat_capture_pi.sh` (shellcheck if installed; `bash -n` mandatory) → no output.

- [ ] **Step 3: Commit** — `git commit -m "feat(pi-wxsat): record-only capture script with dongle recovery ladder"`

---

### Task 4: pi-wxsat provisioner — scheduler/http/prune units

**Files:**
- Modify: `terraform/modules/pi-wxsat/main.tf` (templatefile vars)
- Modify: `terraform/modules/pi-wxsat/provision-wxsat.sh.tpl` (append section 5)

**Interfaces:**
- Consumes: Task 1–3 files via `file()`.
- Produces: on goes.srvr — `/opt/wxsat-pi/{wxsat_predict.py,
  wxsat_record_rtltcp.py, wxsat_live.py, wxsat_scheduler_pi.py,
  wxsat_capture_pi.sh}`; `/etc/wxsat/wxsat.env`; units `wxsat-scheduler`
  (root), `wxsat-http` (:8078, root of `/var/lib/wxsat/http`),
  `wxsat-prune.timer` (daily, 72 h). rgardner keeps NOPASSWD sudo (existing) —
  scheduler runs as root so systemctl/usbreset in the ladder need no sudoers
  work (`sudo` in the script is a no-op passthrough for root).

- [ ] **Step 1: main.tf — extend the templatefile map**

```hcl
  provision_script = templatefile("${path.module}/provision-wxsat.sh.tpl", {
    serial    = try(local.dev.serial, "wxsat0001")
    bind_addr = var.rtltcp_bind
    port      = try(local.dev.port, 1234)
    gain      = var.rtltcp_gain
    # Pi-local capture stack (2026-07-02): shared modules come from
    # radio-compute so there is ONE source of truth for predict/record/live.
    wxsat_predict_py   = file("${path.module}/../radio-compute/wxsat_predict.py")
    wxsat_record_py    = file("${path.module}/../radio-compute/wxsat_record_rtltcp.py")
    wxsat_live_py      = file("${path.module}/../radio-compute/wxsat_live.py")
    wxsat_scheduler_py = file("${path.module}/wxsat_scheduler_pi.py")
    wxsat_capture_sh   = file("${path.module}/wxsat_capture_pi.sh")
  })
```

- [ ] **Step 2: provision-wxsat.sh.tpl — append after the rtl_tcp section**

```bash
# --- 5) Pi-LOCAL capture stack (2026-07-02) ----------------------------------
# Capture became Pi-local so a Garage-UDB link flap can't kill a pass: this
# scheduler records from the localhost rtl_tcp into /var/lib/wxsat/captures and
# the rack's wxsat-sync pulls + decodes. Code is provisioner-owned; wxsat.env
# is keep-if-absent (operator-tunable).
if ! python3 -c 'import pyorbital' >/dev/null 2>&1; then
  command -v pip3 >/dev/null 2>&1 || apt-get install -y python3-pip >/dev/null 2>&1 || true
  echo "    installing pyorbital (pip)"
  pip3 install --break-system-packages pyorbital >/dev/null 2>&1 || \
    echo "    WARN: pyorbital install failed — Pi scheduler will not predict"
fi
python3 -c 'import numpy' >/dev/null 2>&1 || apt-get install -y python3-numpy >/dev/null 2>&1 || true
python3 -c 'import requests' >/dev/null 2>&1 || apt-get install -y python3-requests >/dev/null 2>&1 || true
command -v usbreset >/dev/null 2>&1 || echo "    WARN: usbreset missing (usbutils) — ladder step 2 degraded"

install -d -m 0755 /opt/wxsat-pi /var/lib/wxsat/captures /var/lib/wxsat/tle /var/lib/wxsat/http /run/wxsat
ln -sfn /run/wxsat /var/lib/wxsat/http/live
ln -sfn /var/lib/wxsat/captures /var/lib/wxsat/http/captures
# /run is tmpfs — recreate the runtime dir at boot, before the units start.
echo "d /run/wxsat 0755 root root -" > /etc/tmpfiles.d/wxsat.conf

cat > /opt/wxsat-pi/wxsat_predict.py <<'PYEOF'
${wxsat_predict_py}
PYEOF
cat > /opt/wxsat-pi/wxsat_record_rtltcp.py <<'PYEOF'
${wxsat_record_py}
PYEOF
cat > /opt/wxsat-pi/wxsat_live.py <<'PYEOF'
${wxsat_live_py}
PYEOF
cat > /opt/wxsat-pi/wxsat_scheduler_pi.py <<'PYEOF'
${wxsat_scheduler_py}
PYEOF
cat > /opt/wxsat-pi/wxsat_capture_pi.sh <<'EOF'
${wxsat_capture_sh}
EOF
chmod +x /opt/wxsat-pi/wxsat_scheduler_pi.py /opt/wxsat-pi/wxsat_capture_pi.sh \
         /opt/wxsat-pi/wxsat_record_rtltcp.py /opt/wxsat-pi/wxsat_live.py

if [ -f /etc/wxsat/wxsat.env ]; then
  echo "    /etc/wxsat/wxsat.env exists - keeping it"
else
  cat > /etc/wxsat/wxsat.env <<EOF
# Pi-local Meteor capture (goes.srvr). systemd EnvironmentFile — '#' only at
# line start. DRY_RUN=0: capture-always is the point of the Pi-local design.
DRY_RUN=0
WXSAT_RTLTCP_PORT=${port}
WXSAT_SAMPLERATE=250000
# E4000 SMArTee XTR: AGC (empty). See wxsat notes before setting manual gain.
WXSAT_GAIN_TENTHS=
FREQ_MHZ=137.9
MIN_ELEV_DEG=8
PREDICT_HOURS=48
M2_4_ENABLED=1
M2_3_ENABLED=1
LAT=37.31
LON=-89.55
ALT_KM=0.1
LRPT_PIPELINE=meteor_m2-x_lrpt
WXSAT_MIN_FREE_GB=4
AOS_BUFFER_S=45
POST_LOS_S=15
REFRESH_INTERVAL_S=1800
WXSAT_DIR=/var/lib/wxsat
WXSAT_PASSES_PATH=/run/wxsat/wxsat_passes.json
WXSAT_STATUS_PATH=/run/wxsat/wxsat_status.json
WXSAT_CAPTURES_DIR=/var/lib/wxsat/captures
EOF
  echo "    wrote /etc/wxsat/wxsat.env"
fi

cat > /etc/systemd/system/wxsat-scheduler.service <<'EOF'
[Unit]
Description=wxsat Pi-local Meteor capture scheduler (records localhost rtl_tcp)
Documentation=https://github.com/robertegardner/platform
After=wxsat-rtltcp.service time-sync.target
Wants=wxsat-rtltcp.service

[Service]
Type=simple
EnvironmentFile=/etc/wxsat/wxsat.env
ExecStart=/usr/bin/python3 /opt/wxsat-pi/wxsat_scheduler_pi.py
Restart=always
RestartSec=15
Nice=10

[Install]
WantedBy=multi-user.target
EOF

cat > /etc/systemd/system/wxsat-http.service <<'EOF'
[Unit]
Description=wxsat capture/live HTTP (rack sync + live relay read this)
After=network.target

[Service]
Type=simple
ExecStart=/usr/bin/python3 -m http.server 8078 --directory /var/lib/wxsat/http --bind 0.0.0.0
Restart=always
RestartSec=10
Nice=10

[Install]
WantedBy=multi-user.target
EOF

cat > /etc/systemd/system/wxsat-prune.service <<'EOF'
[Unit]
Description=wxsat capture prune (72h — the rack pulls within minutes when the link is up)

[Service]
Type=oneshot
ExecStart=/usr/bin/find /var/lib/wxsat/captures -mindepth 1 -maxdepth 1 -type d -mmin +4320 -exec rm -rf {} +
EOF

cat > /etc/systemd/system/wxsat-prune.timer <<'EOF'
[Unit]
Description=Daily wxsat capture prune

[Timer]
OnCalendar=daily
Persistent=true

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable wxsat-scheduler.service wxsat-http.service wxsat-prune.timer >/dev/null 2>&1 || true
systemctl restart wxsat-scheduler.service wxsat-http.service || true
systemctl restart wxsat-prune.timer || true
echo "==> pi-wxsat local-capture: scheduler=$(systemctl is-active wxsat-scheduler.service) http=$(systemctl is-active wxsat-http.service)"
```

NB the header comment of the `.tpl` (still says "p24 / thin") — update the top
comment block to say goes.srvr + Pi-local capture, and section 4's "rack's
SatDump sets 137.9 per pass" comment now reads "the Pi capture client sets".

- [ ] **Step 3: Verify** — `terraform -chdir=terraform validate` → `Success!` (run `terraform -chdir=terraform init -backend=false` first if providers are missing locally).

- [ ] **Step 4: Commit** — `git commit -m "feat(pi-wxsat): provision Pi-local capture stack (scheduler/http/prune)"`

---

### Task 5: Rack — wxsat-sync + decode-only mode + live relay

**Files:**
- Create: `terraform/modules/radio-compute/wxsat_sync.py`
- Create: `terraform/modules/radio-compute/wxsat_live_relay.py`
- Modify: `terraform/modules/radio-compute/wxsat_capture_rack.sh` (decode-only mode)
- Modify: `terraform/modules/radio-compute/main.tf` (2 new templatefile vars)
- Modify: `terraform/modules/radio-compute/provision-radio.sh.tpl` (unit swap)

**Interfaces:**
- Consumes: Pi capture-dir contract (Task 2/3): `capture.done|capture.failed`,
  `passmeta.json`, `baseband.cu8`; Pi HTTP `:8078/live/wxsat_live.json`;
  existing `wxsat_scheduler.record_outcome/_best_product/write_status` and
  `wxsat_notify.notify`.
- Produces: decoded products + `captures.json` in `/var/lib/sdr-streams/wxsat/`
  (unchanged layout); `decode.done` marker per capture dir (rack copy);
  `/run/sdr-streams/wxsat_live.json` mirrored during passes.

- [ ] **Step 1: `wxsat_capture_rack.sh` — decode-only mode**

Wrap the record block (the `echo "wxsat-rack: recording..."` line through the
`rc=12` short-recording warning) in:

```bash
if [[ "$${WXSAT_DECODE_ONLY:-0}" == "1" ]]; then
  echo "wxsat-rack: decode-only mode (baseband pulled from the Pi)"
  if [[ ! -s "$IQ" ]]; then
    echo "wxsat-rack: no baseband present at $IQ" >&2
    exit 12
  fi
else
  ... existing record block unchanged ...
fi
```

(This file is embedded via `templatefile()` var, NOT inline in the `.tpl`, so
plain `${...}` bash syntax stays as-is — no `$$` doubling in this file.)

- [ ] **Step 2: `wxsat_sync.py`**

```python
#!/usr/bin/env python3
"""wxsat_sync.py — rack side of the Pi-local Meteor pipeline (.84).

One tick (systemd timer, ~5 min): refresh the pass forecast for the gallery,
pull completed capture dirs from the Pi (goes.srvr), decode any that lack a
decode.done marker (decode-only wxsat_capture_rack.sh), index + ntfy via the
same record_outcome the old streaming scheduler used. Idempotent: markers gate
everything; reruns are no-ops. The Pi being unreachable just means this tick
does prediction only.
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
    """Names of Pi capture dirs holding a completion marker."""
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
    # Gallery forecast + status (the old scheduler used to own these).
    try:
        passes = predict.compute_passes(cfg)
        predict.write_passes(passes, cfg)
        upcoming = [p for p in passes if p["aos_unix"] > time.time()]
        sched.write_status(cfg, "scheduled" if upcoming else "idle",
                           next_pass=min(upcoming, key=lambda p: p["aos_unix"])
                           if upcoming else None)
    except Exception as e:
        log.warning("prediction failed: %s", e)
    names = list_remote_complete()
    if names is None:
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
```

- [ ] **Step 3: `wxsat_live_relay.py`**

```python
#!/usr/bin/env python3
"""wxsat_live_relay.py — mirror the Pi's live-pass telemetry to the rack (.84).

The tuner's /api/wxsat/live reads /run/sdr-streams/wxsat_live.json and treats
frames older than 8 s as {live:false}. During a Pi-local capture the sidecar
runs ON THE PI, so this daemon polls the Pi's wxsat-http and forwards only
FRESH frames to that same path — the UI is unchanged, and while the rack-side
decode phase runs, the rack's own sidecar owns the file (we only write frames
the Pi stamped in the last 8 s, so the two never fight).
"""
import json
import os
import time
import urllib.request

SRC = os.environ.get("WXSAT_PI_LIVE_URL",
                     "http://goes.srvr:8078/live/wxsat_live.json")
DST = os.environ.get("WXSAT_LIVE_PATH", "/run/sdr-streams/wxsat_live.json")
POLL_S = float(os.environ.get("WXSAT_RELAY_POLL_S", "1.5"))

while True:
    try:
        with urllib.request.urlopen(SRC, timeout=2) as r:
            data = json.loads(r.read())
        if time.time() - data.get("updated", 0) <= 8:
            tmp = DST + ".tmp"
            with open(tmp, "w") as f:
                json.dump(data, f)
            os.replace(tmp, DST)
    except Exception:
        pass  # link down / no capture running — nothing to relay
    time.sleep(POLL_S)
```

- [ ] **Step 4: main.tf — add templatefile vars**

Next to `wxsat_scheduler_py = ...` add:

```hcl
    wxsat_sync_py       = file("${path.module}/wxsat_sync.py")
    wxsat_live_relay_py = file("${path.module}/wxsat_live_relay.py")
```

- [ ] **Step 5: provision-radio.sh.tpl — swap the units**

In the `%{ if wxsat_enabled }` block:

a. After the `wxsat_live.py` heredoc add two more:

```bash
cat > /opt/wxsat/wxsat_sync.py <<'PYEOF'
${wxsat_sync_py}
PYEOF
cat > /opt/wxsat/wxsat_live_relay.py <<'PYEOF'
${wxsat_live_relay_py}
PYEOF
```
and add both to the `chmod +x` line.

b. Append to the keep-if-absent `wxsat.env` heredoc (fresh-write only; the
plan's deploy step adds them to the LIVE env by hand since the file is kept):

```bash
WXSAT_PI_HOST=${wxsat_rtltcp_host}
WXSAT_PI_USER=rgardner
WXSAT_PI_CAPTURES=/var/lib/wxsat/captures
WXSAT_PI_LIVE_URL=http://${wxsat_rtltcp_host}:8078/live/wxsat_live.json
```

c. Add a sync ssh key (least-privilege, goes-archive pattern) before the units:

```bash
# Dedicated pull key for wxsat-sync (radio user). ONE-TIME: authorise the
# printed pubkey on goes.srvr as rgardner.
install -d -m 0700 -o radio -g radio /var/lib/sdr-streams/wxsat/.ssh
if [ ! -f /var/lib/sdr-streams/wxsat/.ssh/id_wxsat ]; then
  sudo -u radio ssh-keygen -t ed25519 -N "" -C "wxsat-sync" \
    -f /var/lib/sdr-streams/wxsat/.ssh/id_wxsat >/dev/null
  echo "    ONE-TIME: authorise on goes.srvr (rgardner): $(cat /var/lib/sdr-streams/wxsat/.ssh/id_wxsat.pub)"
fi
```

d. REPLACE the `wxsat-scheduler.service` heredoc + enable/restart lines with:

```bash
# The streaming scheduler is superseded by the Pi-local pipeline (2026-07-02):
# the Pi captures autonomously; this box pulls + decodes on a timer and relays
# live telemetry. Retire the old unit if present.
if [ -f /etc/systemd/system/wxsat-scheduler.service ]; then
  systemctl disable --now wxsat-scheduler.service >/dev/null 2>&1 || true
  rm -f /etc/systemd/system/wxsat-scheduler.service
  echo "    retired wxsat-scheduler.service (replaced by wxsat-sync)"
fi

cat > /etc/systemd/system/wxsat-sync.service <<'EOF'
[Unit]
Description=wxsat sync — pull Pi Meteor captures, decode, index, notify
After=network-online.target

[Service]
Type=oneshot
User=radio
Group=radio
Environment=HOME=/var/lib/sdr-streams/wxsat
EnvironmentFile=/etc/radio-compute/wxsat.env
ExecStart=/usr/bin/python3 /opt/wxsat/wxsat_sync.py
TimeoutStartSec=3600
EOF

cat > /etc/systemd/system/wxsat-sync.timer <<'EOF'
[Unit]
Description=wxsat sync every 5 min

[Timer]
OnBootSec=2min
OnUnitInactiveSec=5min
Persistent=true

[Install]
WantedBy=timers.target
EOF

cat > /etc/systemd/system/wxsat-live-relay.service <<'EOF'
[Unit]
Description=wxsat live-pass telemetry relay (Pi wxsat-http -> /run/sdr-streams)
After=network-online.target

[Service]
Type=simple
User=radio
Group=radio
EnvironmentFile=/etc/radio-compute/wxsat.env
ExecStart=/usr/bin/python3 /opt/wxsat/wxsat_live_relay.py
Restart=always
RestartSec=10
Nice=10

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable wxsat-sync.timer wxsat-live-relay.service >/dev/null 2>&1 || true
systemctl restart wxsat-sync.timer wxsat-live-relay.service || true
echo "    wxsat: sync.timer=$(systemctl is-active wxsat-sync.timer) live-relay=$(systemctl is-active wxsat-live-relay.service)"
```

- [ ] **Step 6: Verify** — `python3 -m py_compile terraform/modules/radio-compute/wxsat_sync.py terraform/modules/radio-compute/wxsat_live_relay.py && bash -n terraform/modules/radio-compute/wxsat_capture_rack.sh && terraform -chdir=terraform validate` → `Success!`

- [ ] **Step 7: Commit** — `git commit -m "feat(radio-compute): wxsat-sync pull+decode timer + live relay; decode-only capture mode"`

---

### Task 6: Deploy — Pi via terraform, rack via manual staging

- [ ] **Step 1: Ship + apply pi_wxsat** (thebeast holds tfvars/state):

```bash
rsync -az terraform tools docs deploy@192.168.6.163:/home/deploy/platform/
ssh deploy@192.168.6.163 'cd /home/deploy/platform/terraform && \
  terraform taint "module.pi_wxsat[0].null_resource.provision[0]" 2>/dev/null; \
  terraform taint "module.pi_wxsat.null_resource.provision[0]" 2>/dev/null; \
  terraform apply -target=module.pi_wxsat -auto-approve'
```
Expected: apply completes; provisioner echoes `pi-wxsat local-capture:
scheduler=active http=active`. NOTE the registry serial change (74111838)
rewrites rtltcp.env only if absent — verify live rtltcp.env already says
74111838 (it was hand-edited at the dongle swap); if not, fix it live +
restart wxsat-rtltcp.

- [ ] **Step 2: Verify Pi side**

```bash
ssh rgardner@192.168.6.134 'systemctl is-active wxsat-scheduler wxsat-http wxsat-rtltcp; journalctl -u wxsat-scheduler -n 5 --no-pager'
curl -s http://192.168.6.134:8078/live/ | head -3
```
Expected: all `active`; scheduler log shows "wxsat PI scheduler up ... next:"
with a pass list; HTTP returns a directory listing.

- [ ] **Step 3: Stage the rack (.84) manually** (avoids a full radio-compute
re-provision that would bounce the audio units; staged == provisioner output):

```bash
# from codeserver, via thebeast (.84 root)
for f in wxsat_predict.py wxsat_live.py wxsat_scheduler.py wxsat_capture_rack.sh wxsat_sync.py wxsat_live_relay.py; do
  scp terraform/modules/radio-compute/$f deploy@192.168.6.163:/tmp/$f
  ssh deploy@192.168.6.163 "scp -i ~/.ssh/id_rsa_homelab /tmp/$f root@192.168.6.84:/opt/wxsat/$f && rm /tmp/$f"
done
```
Then on .84 (via thebeast ssh): `chmod +x` the two new files, write the three
unit files EXACTLY as in Task 5 step 5d, append the four `WXSAT_PI_*` lines to
`/etc/radio-compute/wxsat.env`, generate + print the sync key (Task 5 step 5c
commands), `systemctl daemon-reload`, disable/rm `wxsat-scheduler.service`,
enable+restart `wxsat-sync.timer wxsat-live-relay.service`.

- [ ] **Step 4: Authorize the sync key on the Pi**

```bash
# codeserver has direct ssh to goes.srvr
ssh deploy@192.168.6.163 "ssh -i ~/.ssh/id_rsa_homelab root@192.168.6.84 'cat /var/lib/sdr-streams/wxsat/.ssh/id_wxsat.pub'" | \
  ssh rgardner@192.168.6.134 'cat >> ~/.ssh/authorized_keys'
```
Then from .84: `sudo -u radio ssh -i /var/lib/sdr-streams/wxsat/.ssh/id_wxsat -o BatchMode=yes rgardner@goes.srvr echo OK` → `OK`.

- [ ] **Step 5: Commit any deploy-forced fixes**; update `docs/session_notes.md` with the cutover entry.

---

### Task 7: End-to-end verification

- [ ] **Step 1: Forced 60 s capture on the Pi**

```bash
ssh rgardner@192.168.6.134 'sudo systemctl stop wxsat-scheduler && sudo env $(sudo grep -v "^#" /etc/wxsat/wxsat.env | xargs) python3 /opt/wxsat-pi/wxsat_scheduler_pi.py --capture-now 60; sudo systemctl start wxsat-scheduler'
```
Expected: capture dir under `/var/lib/wxsat/captures/` with `baseband.cu8`
(~30 MB), `passmeta.json`, `capture.done`; `wxsat-rtltcp` back to serving.

- [ ] **Step 2: Live view during the capture** (run while step 1 records):
`curl -s http://192.168.6.84:8080/api/wxsat/live | head -c 200` → `{"live": true, ...spectrum...}`; after LOS → `{"live": false}`.

- [ ] **Step 3: Sync tick decodes it**

```bash
ssh deploy@192.168.6.163 "ssh -i ~/.ssh/id_rsa_homelab root@192.168.6.84 'WXSAT_DECODE_TIMEOUT=120 systemctl start wxsat-sync.service; journalctl -u wxsat-sync -n 20 --no-pager'"
```
Expected: "processing <ts>Z", decode runs (NOSYNC on a 60 s no-signal grab is
CORRECT — outcome `failed/no image` with ntfy), `decode.done` present,
`captures.json` gained the record, gallery row visible at
`radio.rg2.io/wxsat`.

- [ ] **Step 4: Idempotence** — `systemctl start wxsat-sync.service` again →
log says "in sync (... none new)"; no duplicate captures.json entry/ntfy.

- [ ] **Step 5: The real test** — leave it; next scheduled Meteor pass captures
on the Pi regardless of link state, and appears decoded on the gallery within
~5 min of LOS (link up) or of link restoration. Check after the next pass.

- [ ] **Step 6: Docs + memory** — session_notes entry; update the
`wxsat-meteor-on-p24` memory (architecture now store-and-forward); PR the
branch.
