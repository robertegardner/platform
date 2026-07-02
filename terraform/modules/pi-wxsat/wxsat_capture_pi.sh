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
# Exit: 0 recorded (capture.done written); 12 nothing usable (capture.failed).
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

# Reclaim SD space: drop the oldest retained basebands first (markers/logs
# survive, and anything old enough to reclaim has been pulled by the rack
# already whenever the link was up).
need_gb=$(( (DUR * SAMPLERATE * 2 / 1000000000) + MIN_FREE_GB + 1 ))
while [[ "$(free_gb)" =~ ^[0-9]+$ && "$(free_gb)" -lt "$need_gb" ]]; do
  oldest="$(ls -1tr "$CAPTURES_ROOT"/*/baseband.cu8 2>/dev/null | grep -vF -- "$IQ" | head -1)"
  [[ -z "$oldest" ]] && { echo "wxsat-pi: low disk ($(free_gb)G < ${need_gb}G), nothing to reclaim" >&2; break; }
  echo "wxsat-pi: low disk — reclaiming $oldest" >&2
  rm -f "$oldest"
done

# Resolve the Meteor dongle's bus/dev for usbreset — by serial ONLY. Returns
# nothing if the serial isn't found (never guess: the GOES dongle and any
# future sticks must be untouchable).
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
