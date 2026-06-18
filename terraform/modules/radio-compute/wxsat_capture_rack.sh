#!/bin/bash
# wxsat_capture_rack.sh — record a Meteor-M LRPT pass from p24's rtl_tcp and
# decode it with SatDump on the rack (.84).
#
# UNLIKE the Pi's wxsat_capture.sh there is NO SDR contention: the Nooelec is
# dedicated, so we never stop/restart a stream. We just record CU8 from p24's
# rtl_tcp into a baseband file, then decode it offline with SatDump 2.0:
#
#   satdump pipeline meteor_m2-x_lrpt baseband <iq> <out> \
#           --baseband_format u8 --samplerate 1024000
#
# A symbol-rate mismatch looks identical to no signal (NOSYNC), so on no image
# we retry the other Meteor LRPT rate (72k<->80k) before declaring failure. On
# total failure we keep the IQ for offline post-mortem (disk-floor permitting).
#
# Env (from wxsat.env / the scheduler):
#   WXSAT_OUT_DIR  WXSAT_DURATION  WXSAT_SAMPLERATE  WXSAT_FREQ_HZ
#   WXSAT_RTLTCP_HOST  WXSAT_RTLTCP_PORT  WXSAT_GAIN_TENTHS
#   LRPT_PIPELINE  LRPT_PIPELINE_FALLBACK  WXSAT_BB_FORMAT(u8)
#   WXSAT_KEEP_IQ_ON_FAIL(1)  WXSAT_KEEP_IQ_ALWAYS(0)  WXSAT_MIN_FREE_GB(2)
#
# Exit: 0 image decoded; 12 no/short IQ; 13 no pipeline produced an image.
set -uo pipefail

OUT="${WXSAT_OUT_DIR:?WXSAT_OUT_DIR required}"
DUR="${WXSAT_DURATION:?WXSAT_DURATION required}"
SAMPLERATE="${WXSAT_SAMPLERATE:-1024000}"
PIPELINE="${LRPT_PIPELINE:-meteor_m2-x_lrpt}"
BB_FORMAT="${WXSAT_BB_FORMAT:-u8}"
KEEP_IQ_ON_FAIL="${WXSAT_KEEP_IQ_ON_FAIL:-1}"
KEEP_IQ_ALWAYS="${WXSAT_KEEP_IQ_ALWAYS:-0}"
MIN_FREE_GB="${WXSAT_MIN_FREE_GB:-2}"
# SatDump 2.0-alpha resolves its plugin dir as ./plugins relative to cwd (the
# build bakes no absolute path), so we run it from a dir holding that symlink.
SATDUMP_WD="${SATDUMP_WD:-/opt/wxsat/sdwd}"
WXSAT_DIR="$(dirname "$OUT")"
export HOME="${HOME:-/var/lib/sdr-streams/wxsat}"
TLE_DIR="$WXSAT_DIR/tle"
IQ="$OUT/baseband.cu8"
KEEP_IQ="$KEEP_IQ_ALWAYS"

# Fallback rate: explicit env wins, else swap 72k<->80k automatically.
FALLBACK_PIPELINE="${LRPT_PIPELINE_FALLBACK:-}"
if [[ -z "$FALLBACK_PIPELINE" ]]; then
  if [[ "$PIPELINE" == *_80k ]]; then FALLBACK_PIPELINE="meteor_m2-x_lrpt"
  else FALLBACK_PIPELINE="meteor_m2-x_lrpt_80k"; fi
fi

mkdir -p "$OUT"
LOG="$OUT/capture.log"
exec > >(tee -a "$LOG") 2>&1
echo "wxsat-rack: capture starting $(date -u +%Y-%m-%dT%H:%M:%SZ) keep_iq_always=${KEEP_IQ_ALWAYS}"

free_gb() { df -BG --output=avail "$OUT" 2>/dev/null | tail -1 | tr -dc '0-9'; }

cleanup() {
  if [[ "$KEEP_IQ" == "1" && -s "$IQ" ]]; then
    free="$(free_gb)"
    if [[ -n "$free" && "$free" -lt "$MIN_FREE_GB" ]]; then
      echo "wxsat-rack: only ${free}G free (< ${MIN_FREE_GB}G) — dropping IQ despite keep" >&2
      KEEP_IQ=0
    fi
  fi
  [[ "$KEEP_IQ" != "1" ]] && rm -f "$IQ"
  return 0
}
trap cleanup EXIT INT TERM

# Seed SatDump's TLEs from our cache so georeferenced products have fresh elements.
mkdir -p "$HOME/.config/satdump"
if ls "$TLE_DIR"/*.tle >/dev/null 2>&1; then
  cat "$TLE_DIR"/*.tle > "$HOME/.config/satdump/satdump_tles.txt"
fi

# Reclaim space before recording (CU8 ~= SAMPLERATE*2 B/s). Delete oldest retained
# baseband first; small capture.logs + products always survive.
need_gb=$(( (DUR * SAMPLERATE * 2 / 1000000000) + MIN_FREE_GB + 1 ))
while [[ "$(free_gb)" =~ ^[0-9]+$ && "$(free_gb)" -lt "$need_gb" ]]; do
  oldest="$(ls -1tr "$WXSAT_DIR"/*/baseband.cu8 2>/dev/null | grep -vF -- "$IQ" | head -1)"
  [[ -z "$oldest" ]] && { echo "wxsat-rack: low disk ($(free_gb)G < ${need_gb}G), nothing to reclaim" >&2; break; }
  echo "wxsat-rack: low disk — reclaiming $oldest" >&2
  rm -f "$oldest"
done

echo "wxsat-rack: recording ${DUR}s from rtl_tcp ${WXSAT_RTLTCP_HOST:-p24.srvr}:${WXSAT_RTLTCP_PORT:-1234} -> $IQ"
python3 /opt/wxsat/wxsat_record_rtltcp.py "$IQ" "$DUR"
rc=$?
if [[ ! -s "$IQ" ]]; then
  echo "wxsat-rack: no IQ recorded (rc=$rc)" >&2
  exit 12
fi
if [[ $rc -eq 12 ]]; then
  echo "wxsat-rack: WARNING short recording (rc=12) — decoding what we got" >&2
fi

# A real image product (>10k PNG) anywhere under $OUT means a successful decode.
have_image() { [[ -n "$(find "$OUT" -name '*.png' -size +10k 2>/dev/null | head -1)" ]]; }

decode_with() {
  local pl="$1"
  echo "wxsat-rack: decoding $(du -h "$IQ" | cut -f1) baseband with ${pl} (${BB_FORMAT} @ ${SAMPLERATE})"
  # SatDump 2.0 needs --opt=value (space form leaks the value), and the plugin
  # dir is ./plugins relative to cwd -> run from SATDUMP_WD. I/O paths are absolute.
  ( cd "$SATDUMP_WD" && satdump pipeline "$pl" baseband "$IQ" "$OUT" \
      --baseband_format="$BB_FORMAT" --samplerate="$SAMPLERATE" ) || true
  if have_image; then
    echo "wxsat-rack: ${pl} produced an image"
    return 0
  fi
  echo "wxsat-rack: ${pl} produced no image" >&2
  return 1
}

if decode_with "$PIPELINE"; then
  :
elif [[ "$FALLBACK_PIPELINE" != "$PIPELINE" ]] && decode_with "$FALLBACK_PIPELINE"; then
  echo "wxsat-rack: primary ${PIPELINE} empty; fallback ${FALLBACK_PIPELINE} synced"
else
  if [[ "$KEEP_IQ_ON_FAIL" == "1" ]]; then
    KEEP_IQ=1
    echo "wxsat-rack: no pipeline produced an image — retaining IQ for post-mortem: $IQ" >&2
  fi
  exit 13
fi

[[ "$KEEP_IQ_ALWAYS" != "1" ]] && rm -f "$IQ"
echo "wxsat-rack: capture complete -> $OUT"
