#!/usr/bin/env bash
# Rendered by Terraform (templatefile), executed as root in the scanner-compute
# LXC. RE-RUN SAFE: source builds are guarded build-if-absent; hand-tunable
# configs are written only if absent; registry-rendered envs are ALWAYS
# rewritten (they follow the device registry — that is the plug-and-play path
# for the Airspy R2: flip `present` in devices.json, re-apply, restart units).
#
# No vendor SDR drivers here — samples arrive over SoapyRemote from the Pi.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

echo "==> base packages (SoapyRemote client + gnuradio/gr-osmosdr + audio chain)"
apt-get update -qq
apt-get install -y -qq \
  soapysdr-tools soapysdr-module-remote python3-soapysdr \
  gnuradio gnuradio-dev gr-osmosdr \
  libhackrf-dev libitpp-dev libpcap-dev liborc-0.4-dev libsndfile1-dev \
  python3-numpy python3-waitress python3-requests python3-setuptools \
  ffmpeg sox liquidsoap \
  git cmake build-essential pkg-config curl

echo "==> verify gr-osmosdr carries the soapy plugin"
# This is the ONLY path to the remote source (no rtl_tcp fallback in V2; the
# Airspy R2 isn't RTL). Fail loudly if the distro build dropped it.
# NB: grep WITHOUT -q — under pipefail, grep -q exiting at first match can
# SIGPIPE the producer and fail the pipeline on a genuine match (bit us
# 2026-06-10: a correct soapy link reported FATAL).
OSMO_LIB="$(ldconfig -p | awk '/libgnuradio-osmosdr/ {print $NF; exit}')"
if [ -z "$OSMO_LIB" ] || ! ldd "$OSMO_LIB" | grep -i soapy >/dev/null; then
  echo "FATAL: gr-osmosdr has no SoapySDR support — op25 cannot reach the remote source"
  exit 1
fi
echo "    soapy plugin OK ($OSMO_LIB)"

echo "==> socket buffer headroom (informational)"
# net.core.rmem_max is host-global and read-only in an unprivileged LXC. The
# interim rtl-2838 stream (CU8 @ 2.4 Msps ~ 5 MB/s) fits the default; before
# high-rate phases (Airspy R2 at full rate, dx-R2 8 Msps into radio-compute)
# raise rmem_max/wmem_max on THEBEAST (host kernel) — see deployment_notes.md.
echo "    host net.core.rmem_max = $(sysctl -n net.core.rmem_max 2>/dev/null || echo 'unreadable')"

echo "==> scanner user + directories"
id -u scanner >/dev/null 2>&1 || useradd --system --create-home --home-dir /var/lib/scanner-compute --shell /usr/sbin/nologin scanner
mkdir -p /etc/scanner-compute /opt/scanner-compute /var/lib/scanner-compute
chown scanner:scanner /var/lib/scanner-compute

echo "==> registry-rendered source envs (ALWAYS rewritten — registry is the source of truth)"
%{ for id, dev in devices ~}
cat > /etc/scanner-compute/source-${id}.env <<'EOF'
# platform-managed (registry-rendered) — DO NOT hand-edit; terraform re-apply rewrites.
# Device '${id}' (${dev.role}) served from ${dev.endpoint}, wire ${dev.wire_format}.
# Bare driver=remote would open the server's first enumerable device — the
# explicit remote:driver selection below is load-bearing.
OSMOSDR_ARGS=soapy=0,driver=remote,remote=${dev.endpoint},remote:driver=${dev.remote_driver}
SOAPY_ARGS=driver=remote,remote=${dev.endpoint},remote:driver=${dev.remote_driver}
SAMPLE_RATE=${dev.sample_rate}
WIRE_FORMAT=${dev.wire_format}
EOF
echo "    wrote /etc/scanner-compute/source-${id}.env"
%{ endfor ~}

cat > /etc/scanner-compute/scanner.env <<'EOF'
# platform-managed (registry-rendered) — DO NOT hand-edit; terraform re-apply rewrites.
# The scanner-domain device the decode units bind to. When the Airspy R2 joins
# the registry this flips to it automatically (alphabetical preference is
# coincidence-proof: airspy-r2 sorts before rtl-2838).
ACTIVE_SOURCE=${active_source}
EOF
echo "    active scanner source: ${active_source}"

echo "==> Icecast publish env (written-if-absent; secret, mode 0600)"
if [ -f /etc/scanner-compute/icecast.env ]; then
  echo "    icecast.env exists - keeping it"
else
  cat > /etc/scanner-compute/icecast.env <<'EOF'
# Rack Icecast source-client credentials (same password as the Pi's Icecast by
# design — cutovers change only the host).
ICECAST_HOST=${icecast_host}
ICECAST_PORT=${icecast_port}
ICECAST_SOURCE_PASSWORD=${icecast_source_password}
EMS_MOUNT=/ems.mp3
EOF
  chmod 0600 /etc/scanner-compute/icecast.env
fi

echo "==> EMS transcription env (written-if-absent; carries the whisper token)"
# Captions the live rack op25 /ems.mp3 via the remote faster-whisper host
# (TRANSCRIBE_ALWAYS monitor mode). Keep-if-absent so a re-apply never clobbers a
# hand-set token. EMS_RECORDINGS_DIR points at a nonexistent path on purpose:
# op25 has no per-call recordings (that was SDRTrunk's job on the V1 Pi), so the
# call-watch loop must stay a no-op — pointing it at a real dir is what spun the
# Pi's CPU to 32%.
if [ -f /etc/scanner-compute/transcribe.env ]; then
  echo "    transcribe.env exists - keeping it"
else
  cat > /etc/scanner-compute/transcribe.env <<'EOF'
TRANSCRIBE_ENABLED=true
WHISPER_URL=http://gti-ai.srvr:8088
WHISPER_TOKEN=${whisper_token}
TRANSCRIBE_ALWAYS=true
TRANSCRIBE_MONITOR_URL=http://${icecast_host}:${icecast_port}/ems.mp3
TRANSCRIBE_CONTEXT=MOSWIN P25
TRANSCRIBE_WINDOW_SEC=8
TRANSCRIPTS_DIR=/var/lib/scanner-compute/transcripts
TRANSCRIBE_STATE_PATH=/run/scanner/transcribe.json
EMS_RECORDINGS_DIR=/var/lib/scanner-compute/_no_call_recordings
EOF
  chmod 0640 /etc/scanner-compute/transcribe.env
  chown root:scanner /etc/scanner-compute/transcribe.env
fi
install -d -o scanner -g scanner /var/lib/scanner-compute/transcripts

echo "==> op25 (boatbod) build-if-absent — slow on first run"
# Marker v2: set only after the installed python module imports (the first
# 2026-06-10 build configured before python3-setuptools was present, so cmake's
# distutils probe failed and the python install landed wrong — a bare
# "build completed" marker would have kept that broken tree forever).
if [ -f /opt/op25/.platform-built-v2 ]; then
  echo "    op25 already built - keeping it"
else
  rm -rf /opt/op25
  git clone --depth 1 --branch gr310 https://github.com/boatbod/op25.git /opt/op25
  cmake -S /opt/op25 -B /opt/op25/build -DCMAKE_BUILD_TYPE=Release
  cmake --build /opt/op25/build -j"$(nproc)"
  cmake --install /opt/op25/build
  ldconfig
  python3 -c "from gnuradio import op25, op25_repeater" \
    || { echo "FATAL: op25 python modules do not import after install"; exit 1; }
  touch /opt/op25/.platform-built-v2
fi

echo "==> op25 http console hardening (idempotent patch)"
# Upstream http_server.py calls sys.exit(1) on ANY malformed request — a
# proxy health-check or stray POST kills the web console while the decoder
# keeps running (bit us 2026-06-10: both UIs "waiting for data" behind NPM).
# Patch to log + answer 500 instead. Warn-only if upstream shape changed.
python3 - <<'PYEOF' || echo "    WARNING: http_server.py patch did not apply (upstream changed?)"
import sys
p = "/opt/op25/op25/gr-op25_repeater/apps/http_server.py"
s = open(p).read()
if "platform-patched" in s:
    print("    http_server.py already patched")
    sys.exit(0)
old = """    failed = False
    try:
        result = http_request(environ, start_response)
    except Exception:
        failed = True
        sys.stderr.write('application: request failed:\\n%s\\n' % traceback.format_exc())
        sys.exit(1)
    return result"""
new = """    # platform-patched: a malformed request must not kill the console
    # (upstream sys.exit(1) leaves the decoder running but the web UI dead).
    try:
        result = http_request(environ, start_response)
    except Exception:
        sys.stderr.write('application: request failed:\\n%s\\n' % traceback.format_exc())
        try:
            start_response('500 Internal Server Error', [('Content-type', 'text/plain')])
        except Exception:
            pass
        return [b'']
    return result"""
assert old in s
open(p, "w").write(s.replace(old, new, 1))
print("    http_server.py patched")
PYEOF

echo "==> MOSWIN P25 config (written-if-absent — hand-tuned on air, do not clobber)"
# Cape County MOSWIN, proven on air by the Pi SDRTrunk bring-up (2026-06):
# control channel 769.16875 MHz, NAC 0x1CC, system 0x1CE, WACN 0xBEE00,
# P25 Phase II, C4FM control modulation (CQPSK gives ~98% sync loss here).
if [ -f /opt/scanner-compute/moswin-trunk.tsv ]; then
  echo "    moswin-trunk.tsv exists - keeping it"
else
  printf '"%s"\t"%s"\t"%s"\t"%s"\t"%s"\t"%s"\t"%s"\t"%s"\t"%s"\n' \
    "Sysname" "Control Channel List" "Offset" "NAC" "Modulation" "TGID Tags File" "Whitelist" "Blacklist" "Center Frequency" \
    "MOSWIN Cape" "769.16875" "0" "0x1CC" "c4fm" "/opt/scanner-compute/moswin-tgid-tags.tsv" "" "" "" \
    > /opt/scanner-compute/moswin-trunk.tsv
fi

if [ -f /opt/scanner-compute/moswin-tgid-tags.tsv ]; then
  echo "    moswin-tgid-tags.tsv exists - keeping it"
else
  # Source of truth for labels: the Pi's /opt/scanner/p25/moswin_talkgroups.tsv
  # (RadioReference-seeded). Keep the two in sync by hand until scanner v2 owns it.
  cat > /opt/scanner-compute/moswin-tgid-tags.tsv <<'EOF'
4206	CGPD Events (Police)
4229	Jackson PD (Police)
4237	Sheriff / Law Disp (Police)
4242	Fire Paging (Fire)
4244	SEMO Univ Police (Police)
4246	Region E HSRT (Interop)
4249	Fire Dispatch (Fire)
4250	CGPD SWAT (Police)
EOF
fi

if [ -f /opt/scanner-compute/run-op25.sh ]; then
  echo "    run-op25.sh exists - keeping it"
else
  cat > /opt/scanner-compute/run-op25.sh <<'EOF'
#!/usr/bin/env bash
# op25 trunk receiver — Cape County MOSWIN (P25 Phase II). Reads IQ from the
# LOCAL rtl_tcp bridge (rtltcp-bridge.service) on 127.0.0.1:1234, NOT directly
# from SoapyRemote. Why: op25's gr-osmosdr soapy-remote source cannot sustain a
# high-rate remote stream — the Airspy R2 at 2.5 Msps CS16 (~80 Mbps) stalls it
# after ~one buffer (it won't forward remote:prot=tcp to the stream, so the
# transport stays lossy UDP), and op25 won't trunk from a file source. The bridge
# tight-loops the R2 over SoapyRemote (forcing prot=tcp) and re-serves it as
# rtl_tcp CU8 (~40 Mbps, the profile op25 was happy with on the retired RTL);
# op25's SET_FREQ retunes propagate through it so trunk-following works.
# Gain is set SERVER-SIDE in the bridge (IQ_GAINS, /etc/scanner-compute/rtltcp-bridge.env).
# Hand-tunable; write-if-absent.
set -euo pipefail
. /etc/scanner-compute/scanner.env
. "/etc/scanner-compute/source-$ACTIVE_SOURCE.env"

cd /opt/op25/op25/gr-op25_repeater/apps
# -V -w (vocoder + UDP PCM out to 127.0.0.1:23456), NOT -U: -U additionally
# spawns op25's own UDP player, which BINDS the port that ems-stream's
# audio.py needs — a restart-order lottery (bit us 2026-06-10).
exec ./rx.py --nocrypt --args "rtl_tcp=127.0.0.1:1234" \
  -S "$SAMPLE_RATE" -q 0 -T /opt/scanner-compute/moswin-trunk.tsv \
  -2 -V -w -v 1 -l 'http:0.0.0.0:8080' \
  2>>/var/lib/scanner-compute/op25-stderr.log
EOF
  chmod +x /opt/scanner-compute/run-op25.sh
fi

echo "==> rtl_tcp bridge (remote Airspy R2 -> op25; write-if-absent script + env)"
# The bridge that makes op25 work with the high-rate Airspy R2 (see run-op25.sh).
# Script is write-if-absent so hand edits survive; runtime knobs live in the env.
if [ -f /opt/scanner-compute/rtltcp_bridge.py ]; then
  echo "    rtltcp_bridge.py exists - keeping it"
else
  cat > /opt/scanner-compute/rtltcp_bridge.py <<'PYEOF'
${rtltcp_bridge_py}
PYEOF
  chmod +x /opt/scanner-compute/rtltcp_bridge.py
fi
if [ -f /etc/scanner-compute/rtltcp-bridge.env ]; then
  echo "    rtltcp-bridge.env exists - keeping it"
else
  cat > /etc/scanner-compute/rtltcp-bridge.env <<'EOF'
# rtl_tcp bridge runtime knobs (hand-tunable; SOAPY_ARGS comes from the active
# source env via the unit's other EnvironmentFile). Airspy R2 gain elements are
# LNA/MIX/VGA (0-15). CU8_SHIFT scales CS16->CU8 (x>>shift +128); 8 = no clip.
IQ_GAINS=LNA:15,MIX:15,VGA:15
CU8_SHIFT=8
RTLTCP_PORT=1234
IQ_FREQ=769168750
EOF
fi

echo "==> on-demand FM/AM monitor (the V1 tuner; preempts P25 -> /scanner-atc.mp3)"
# monitor.service stops op25 + the bridge to free the R2, NFM/AM-demods one
# channel (monitor_stream.py — the wbfm_stream pattern, prot=tcp) per the runtime
# params scanner-api writes to /var/lib/scanner-compute/monitor.env, publishes
# /scanner-atc.mp3, and auto-returns to P25 after RuntimeMaxSec or on stop.
# (Supersedes the per-freq atc-listen@ template — clean it up on re-provision.)
systemctl stop 'atc-listen@*' 2>/dev/null || true
rm -f /etc/systemd/system/atc-listen@.service /etc/sudoers.d/scanner-atc \
      /opt/scanner-compute/atc-listen.sh /opt/scanner-compute/atc_stream.py \
      /etc/scanner-compute/atc.env
if [ -f /opt/scanner-compute/monitor_stream.py ]; then
  echo "    monitor_stream.py exists - keeping it"
else
  cat > /opt/scanner-compute/monitor_stream.py <<'PYEOF'
${monitor_stream_py}
PYEOF
  chmod +x /opt/scanner-compute/monitor_stream.py
fi
if [ -f /opt/scanner-compute/monitor-tune.sh ]; then
  echo "    monitor-tune.sh exists - keeping it"
else
  cat > /opt/scanner-compute/monitor-tune.sh <<'EOF'
#!/usr/bin/env bash
# On-demand FM/AM monitor: monitor_stream.py (R2) -> mp3 -> rack Icecast
# /scanner-atc.mp3. MON_* (from monitor.env) + ICECAST_* (root-only icecast.env)
# are injected by the unit's EnvironmentFiles — do NOT source them here.
set -euo pipefail
exec bash -c "LD_LIBRARY_PATH=/usr/local/lib python3 /opt/scanner-compute/monitor_stream.py | \
  ffmpeg -hide_banner -loglevel error -f s16le -ar 12500 -ac 1 -i - \
    -codec:a libmp3lame -b:a 24k -content_type audio/mpeg -ice_name 'Monitor' -f mp3 \
    icecast://source:$${ICECAST_SOURCE_PASSWORD}@$${ICECAST_HOST}:$${ICECAST_PORT}/scanner-atc.mp3"
EOF
  chmod +x /opt/scanner-compute/monitor-tune.sh
fi

cat > /etc/systemd/system/monitor.service <<'EOF'
[Unit]
Description=On-demand FM/AM monitor on the R2 (coordinator-managed -> /scanner-atc.mp3)
Conflicts=op25-ems.service rtltcp-bridge.service wx-on-r2.service
After=network-online.target

[Service]
Type=simple
User=scanner
Group=scanner
Environment=LD_LIBRARY_PATH=/usr/local/lib
EnvironmentFile=/etc/scanner-compute/icecast.env
EnvironmentFile=-/var/lib/scanner-compute/monitor.env
ExecStart=/opt/scanner-compute/monitor-tune.sh
Restart=on-failure
RestartSec=8
EOF
# NB: monitor.service no longer self-juggles op25 / auto-returns — the r2-mode
# coordinator (below) owns ALL R2 stop/start + the Pi source bounce. scanner-api's
# monitor_tune/stop delegate to r2-mode.sh (atc/noaa).

# scanner-api (User=scanner) writes monitor.env then restarts/stops the unit.
cat > /etc/sudoers.d/scanner-monitor <<'EOF'
scanner ALL=(root) NOPASSWD: /usr/bin/systemctl restart monitor.service, /usr/bin/systemctl stop monitor.service, /usr/bin/systemctl start monitor.service
EOF
chmod 0440 /etc/sudoers.d/scanner-monitor
visudo -cf /etc/sudoers.d/scanner-monitor >/dev/null || { echo "FATAL: bad scanner-monitor sudoers"; rm -f /etc/sudoers.d/scanner-monitor; exit 1; }

echo "==> R2-mode coordinator (NOAA 162.550 on the discone + single-authority switch)"
# The discone/R2 is single-tuner: NOAA / P25 / ATC are mutually exclusive.
# r2-mode.sh is the single authority — stop all R2 users, BOUNCE the Pi source
# fresh (it degrades on client switches: op25 runs deaf otherwise), then start the
# requested mode. wx-on-r2.service is NOAA (NFM 162.550 -> /wx.mp3) via the same
# monitor_stream the airband monitor uses. scanner-api exposes /api/r2/{state,mode}.
# NOTE (manual, not provisioned — security): the bounce SSHes .83 root -> the Pi as
# a FORCED-COMMAND key authorized only to `systemctl restart sdr-source@airspy-r2`
# (Pi ~rgardner/.ssh/authorized_keys + /etc/sudoers.d/r2-bounce on the Pi). Boot
# enablement (NOAA-default vs op25-default) is left as-is; flip deliberately.
if [ -f /opt/scanner-compute/wx-on-r2.sh ]; then
  echo "    wx-on-r2.sh exists - keeping it"
else
  cat > /opt/scanner-compute/wx-on-r2.sh <<'E'
#!/usr/bin/env bash
# NOAA Weather Radio on the R2/discone -> rack Icecast /wx.mp3. SOAPY_ARGS/MON_*/
# ICECAST_* injected by the unit's env (Environment= + icecast.env).
set -euo pipefail
exec bash -c "LD_LIBRARY_PATH=/usr/local/lib python3 /opt/scanner-compute/monitor_stream.py | \
  ffmpeg -hide_banner -loglevel error -f s16le -ar 12500 -ac 1 -i - \
    -codec:a libmp3lame -b:a 24k -content_type audio/mpeg -ice_name 'NOAA WX (discone)' -f mp3 \
    icecast://source:$${ICECAST_SOURCE_PASSWORD}@$${ICECAST_HOST}:$${ICECAST_PORT}/wx.mp3"
E
  chmod +x /opt/scanner-compute/wx-on-r2.sh
fi
cat > /etc/systemd/system/wx-on-r2.service <<'E'
[Unit]
Description=NOAA Weather Radio on the R2/discone (NFM 162.550 -> /wx.mp3)
Conflicts=op25-ems.service rtltcp-bridge.service monitor.service
After=network-online.target
[Service]
Type=simple
User=scanner
Group=scanner
Environment=SOAPY_ARGS=driver=remote,remote=tcp://radio.srvr:55003,remote:driver=airspy
Environment=MON_FREQ=162550000
Environment=MON_MODE=nfm
Environment=MON_GAINS=LNA:14,MIX:13,VGA:14
Environment=MON_SQUELCH=0.0001
EnvironmentFile=/etc/scanner-compute/icecast.env
ExecStart=/opt/scanner-compute/wx-on-r2.sh
Restart=always
RestartSec=8
[Install]
WantedBy=multi-user.target
E
if [ -f /opt/scanner-compute/r2-mode.sh ]; then
  echo "    r2-mode.sh exists - keeping it"
else
  cat > /opt/scanner-compute/r2-mode.sh <<'E'
#!/usr/bin/env bash
# Single authority for the R2/discone source. Stops all R2 users, bounces the Pi
# source fresh (forced-command key; degrades on switches), then starts the mode.
set -uo pipefail
MODE="$${1:-}"
ALL="wx-on-r2.service monitor.service op25-watch.timer op25-ems.service rtltcp-bridge.service"
systemctl stop $ALL 2>/dev/null || true
sleep 2
if timeout 12 ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new -i /root/.ssh/id_ed25519 rgardner@radio.srvr bounce 2>/dev/null; then
  echo "r2-mode: R2 source bounced fresh"
else
  echo "r2-mode: WARN source bounce failed (op25 may run deaf)" >&2
fi
sleep 5
case "$MODE" in
  noaa) systemctl reset-failed wx-on-r2.service 2>/dev/null || true; systemctl start wx-on-r2.service ;;
  p25)  systemctl reset-failed rtltcp-bridge.service op25-ems.service 2>/dev/null || true
        systemctl start rtltcp-bridge.service op25-ems.service op25-watch.timer ;;
  atc)  systemctl reset-failed monitor.service 2>/dev/null || true; systemctl start monitor.service ;;
  *)    echo "usage: r2-mode.sh {noaa|p25|atc}" >&2; exit 2 ;;
esac
echo "r2-mode -> $MODE"
E
  chmod +x /opt/scanner-compute/r2-mode.sh
fi
cat > /etc/sudoers.d/scanner-r2mode <<'E'
scanner ALL=(root) NOPASSWD: /opt/scanner-compute/r2-mode.sh noaa, /opt/scanner-compute/r2-mode.sh p25, /opt/scanner-compute/r2-mode.sh atc
E
chmod 0440 /etc/sudoers.d/scanner-r2mode
visudo -cf /etc/sudoers.d/scanner-r2mode >/dev/null || { echo "FATAL: bad scanner-r2mode sudoers"; rm -f /etc/sudoers.d/scanner-r2mode; exit 1; }
systemctl daemon-reload

# Liquidsoap, NOT bare ffmpeg: op25 emits UDP PCM only DURING calls, so a
# plain ffmpeg chain stalls between calls and Icecast drops the source
# (proven 2026-06-10). audio.py bridges the UDP audio to stdout and mksafe
# inserts silence, so the mount stays up. Based on op25's
# example_liquidsoap_V2.2.4-2 (matches noble's liquidsoap 2.2.4).
if [ -f /opt/scanner-compute/ems.liq ]; then
  echo "    ems.liq exists - keeping it"
else
  cat > /opt/scanner-compute/ems.liq <<'EOF'
#!/usr/bin/liquidsoap
# EMS audio publish: op25 UDP PCM -> rack Icecast /ems.mp3 (hand-tunable;
# written-if-absent). Password arrives via the unit EnvironmentFile.

settings.log.stdout.set(true)
settings.log.file.set(false)
settings.log.level.set(2)
settings.frame.audio.size.set(8000)

input = input.external.rawaudio(buffer=0.25, channels=2, samplerate=8000,
  restart_on_error=false,
  "python3 /opt/op25/op25/gr-op25_repeater/apps/audio.py -u 23456 -x 1.35 -s")

input = compress(input, attack = 2.0, gain = 0.0, knee = 13.0, ratio = 2.0, release = 12.3, threshold = -18.0)
input = normalize(input, gain_max = 6.0, gain_min = -6.0, target = -16.0, threshold = -65.0)
input_safe = mksafe(input)

output.icecast(%mp3(bitrate=32, samplerate=22050, stereo=true, internal_quality=0),
  description="Cape County MOSWIN (op25)", genre="Public Safety", url="",
  fallible=false, host="${icecast_host}", port=${icecast_port}, mount="/ems.mp3",
  name="MOSWIN All",
  password=environment.get(default="hackme", "ICECAST_SOURCE_PASSWORD"),
  input_safe)
EOF
  chown scanner:scanner /opt/scanner-compute/ems.liq
fi

echo "==> scanner-api env (platform-managed — ALWAYS rewritten)"
# The V1-contract REST bridge for the Android app / V1 clients (:8081, fed by
# op25's http terminal). App CODE (scanner_api.py) comes from the scanner
# repo's deploy.sh (two-cadence) — this lays down only the env + unit.
cat > /etc/scanner-compute/scanner-api.env <<'EOF'
# platform-managed — DO NOT hand-edit; terraform re-apply rewrites.
OP25_TERMINAL_URL=http://127.0.0.1:8080
API_PORT=8081
TGID_TAGS=/opt/scanner-compute/moswin-tgid-tags.tsv
EVENTS_PATH=/var/lib/scanner-compute/call-events.jsonl
# EMS transcripts surfaced by /api/transcribe + /api/transcript (must match
# scanner-transcribe's transcribe.env).
TRANSCRIPTS_DIR=/var/lib/scanner-compute/transcripts
TRANSCRIBE_STATE_PATH=/run/scanner/transcribe.json
EOF

echo "==> systemd units (laid down + reloaded; enable/start happens at cutover)"
cat > /etc/systemd/system/scanner-api.service <<'EOF'
[Unit]
Description=scanner-api: V1-contract REST bridge (op25 terminal -> :8081)
After=network-online.target op25-ems.service
Wants=network-online.target
StartLimitIntervalSec=0

[Service]
Type=simple
User=scanner
Group=scanner
WorkingDirectory=/var/lib/scanner-compute
EnvironmentFile=/etc/scanner-compute/scanner-api.env
ExecStart=/usr/bin/python3 /opt/scanner-compute/scanner_api.py
Restart=always
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF

# EMS transcription orchestrator (Whisper captions of the live /ems.mp3). App
# CODE (transcribe.py) comes from the scanner repo's v2/deploy.sh (two-cadence);
# this lays down only the unit. Monitor-only on the rack (no SDRTrunk recordings).
cat > /etc/systemd/system/scanner-transcribe.service <<'EOF'
[Unit]
Description=Scanner transcription orchestrator (Whisper captions of the rack op25 /ems.mp3)
After=network-online.target ems-stream.service
Wants=network-online.target

[Service]
Type=simple
User=scanner
Group=scanner
WorkingDirectory=/opt/scanner-compute
EnvironmentFile=/etc/scanner-compute/transcribe.env
RuntimeDirectory=scanner
RuntimeDirectoryMode=0755
RuntimeDirectoryPreserve=yes
ExecStart=/usr/bin/python3 /opt/scanner-compute/transcribe.py
Restart=always
RestartSec=10s

[Install]
WantedBy=multi-user.target
EOF

cat > /etc/systemd/system/op25-ems.service <<'EOF'
[Unit]
Description=op25 P25 trunk receiver (Cape County MOSWIN, remote source)
After=network-online.target
Wants=network-online.target
StartLimitIntervalSec=0

[Service]
Type=simple
User=scanner
Group=scanner
WorkingDirectory=/var/lib/scanner-compute
# SIGINT + settle: killing the SoapyRemote client mid-stream wedges the
# server-side device session (same pattern as the dx-R2/FM side) — rx.py
# tears down cleanly on SIGINT; the pre-start sleep lets the server finish
# releasing the dongle before the reopen.
KillSignal=SIGINT
TimeoutStopSec=15
ExecStartPre=/bin/sleep 2
ExecStart=/opt/scanner-compute/run-op25.sh
Restart=on-failure
RestartSec=10s

[Install]
WantedBy=multi-user.target
EOF

# rtl_tcp bridge: tight-loop SoapySDR reader (remote Airspy R2, prot=tcp) re-served
# to op25 as rtl_tcp CU8 (see run-op25.sh for why op25's own soapy-remote source
# can't read the R2). SOAPY_ARGS comes from the active source env; gain/port/shift
# from rtltcp-bridge.env. Runs as scanner (same as op25-ems).
cat > /etc/systemd/system/rtltcp-bridge.service <<'EOF'
[Unit]
Description=rtl_tcp bridge: remote Airspy R2 -> op25 (tight-loop SoapySDR reader, prot=tcp)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=scanner
Group=scanner
Environment=LD_LIBRARY_PATH=/usr/local/lib
EnvironmentFile=/etc/scanner-compute/source-${active_source}.env
EnvironmentFile=/etc/scanner-compute/rtltcp-bridge.env
ExecStart=/usr/bin/python3 /opt/scanner-compute/rtltcp_bridge.py
Restart=on-failure
RestartSec=3s

[Install]
WantedBy=multi-user.target
EOF

# op25 requires the bridge up first. A drop-in (not an edit) so it survives the
# op25-ems.service rewrite above on every re-apply.
mkdir -p /etc/systemd/system/op25-ems.service.d
cat > /etc/systemd/system/op25-ems.service.d/10-rtltcp.conf <<'EOF'
[Unit]
After=rtltcp-bridge.service
Requires=rtltcp-bridge.service
EOF

cat > /etc/systemd/system/ems-stream.service <<'EOF'
[Unit]
Description=EMS audio publish: op25 UDP PCM -> rack Icecast /ems.mp3
After=op25-ems.service
Wants=op25-ems.service

[Service]
Type=simple
User=scanner
Group=scanner
# EnvironmentFile injects the Icecast password (icecast.env is root-readable
# only — the script/liq must NOT try to read it itself as the scanner user).
EnvironmentFile=/etc/scanner-compute/icecast.env
ExecStart=/usr/bin/liquidsoap /opt/scanner-compute/ems.liq
Restart=always
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF

# Decode-starvation watchdog: SoapyRemote flow-control loss (the shared attic
# uplink) can silently starve op25 — the unit stays active and the mount stays
# up (mksafe silence) while TSBKs stop. The bridge already detects staleness
# (current:null after 30s without trunk_updates); two consecutive stale checks
# restart op25-ems (a fresh session re-opens flow control).
cat > /opt/scanner-compute/op25-watch.sh <<'EOF'
#!/usr/bin/env bash
# platform-managed — do not hand-edit; terraform re-apply rewrites.
set -u
STRIKES=/run/op25-watch.strikes
systemctl is-active --quiet op25-ems || { rm -f "$STRIKES"; exit 0; }
cur=$(curl -s -m 5 http://127.0.0.1:8081/api/status | python3 -c 'import json,sys; print(json.load(sys.stdin)["current"] is not None)' 2>/dev/null)
if [ "$cur" = "True" ]; then rm -f "$STRIKES"; exit 0; fi
n=$(($(cat "$STRIKES" 2>/dev/null || echo 0) + 1))
if [ "$n" -ge 2 ]; then
  echo "op25-watch: decode stale twice - restarting op25-ems"
  rm -f "$STRIKES"
  systemctl restart op25-ems
else
  echo "$n" > "$STRIKES"
fi
EOF
chmod +x /opt/scanner-compute/op25-watch.sh

cat > /etc/systemd/system/op25-watch.service <<'EOF'
[Unit]
Description=op25 decode watchdog (restart on silent starvation)

[Service]
Type=oneshot
ExecStart=/opt/scanner-compute/op25-watch.sh
EOF

cat > /etc/systemd/system/op25-watch.timer <<'EOF'
[Unit]
Description=Run the op25 decode watchdog every minute

[Timer]
OnBootSec=3min
OnUnitActiveSec=1min

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
# Boot model (2026-06-18 flip): NOAA is the R2's 24/7 default (wx-on-r2 enabled);
# P25/ATC are on-demand via r2-mode.sh, so the op25 chain + bridge + watchdog are
# laid down but NOT boot-enabled — the coordinator starts op25-ems on demand (it
# pulls rtltcp-bridge via Requires, and r2-mode.sh starts op25-watch.timer too).
# Enablement only here; don't start/stop — the coordinator owns the running mode.
systemctl enable wx-on-r2.service >/dev/null 2>&1 || true
systemctl disable op25-ems.service rtltcp-bridge.service op25-watch.timer >/dev/null 2>&1 || true

echo "==> provisioning complete (units laid down, not started — cutover enables them)"
%{ for id, dev in devices ~}
echo "    device '${id}' -> ${dev.endpoint} (remote:driver=${dev.remote_driver}, ${dev.wire_format} @ ${dev.sample_rate})"
%{ endfor ~}
