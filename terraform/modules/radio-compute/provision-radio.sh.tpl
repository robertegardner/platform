#!/usr/bin/env bash
# Rendered by Terraform (templatefile), executed as root in the radio-compute
# LXC. RE-RUN SAFE: source builds guarded build-if-absent; registry-rendered
# envs ALWAYS rewritten. Toolchain only — the radio repo (v2) deploys app code
# via its own deploy.sh (two-cadence rule). NOTHING is enabled or started:
# the dx-R2 belongs to the live radio on the Pi until the radio cutover.
#
# No vendor SDR drivers here — samples arrive over SoapyRemote from the Pi.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

echo "==> base packages"
apt-get update -qq
apt-get install -y -qq \
  soapysdr-tools soapysdr-module-remote python3-soapysdr libsoapysdr-dev \
  ffmpeg sox python3-venv python3-numpy python3-scipy python3-flask python3-requests \
  git cmake build-essential pkg-config curl \
  autoconf automake libtool meson ninja-build \
  libusb-1.0-0-dev libudev-dev librtlsdr-dev \
  libfftw3-dev libsamplerate0-dev libsndfile1-dev libao-dev \
  libpng-dev libtiff-dev libjemalloc-dev libcurl4-openssl-dev \
  zlib1g-dev libzstd-dev libvolk-dev nlohmann-json3-dev libnng-dev libsqlite3-dev \
  libliquid-dev

echo "==> csdr (build-if-absent)"
# Lightweight DSP pipeline tool — one candidate for the FM leg; the radio repo
# decides csdr vs nrsc5 (both staged so that's an app decision, not re-provision).
# jketterl fork: maintained, cmake-based (upstream ha7ilm's Makefile is broken
# on noble — parsevect Error 127, observed 2026-06-10).
# Marker-guarded (not command -v): the 2026-06-10 first run left a PARTIAL
# ha7ilm install at /usr/bin/csdr that a command -v guard would wrongly keep.
if [ -f /usr/local/share/.csdr-platform-built ]; then
  echo "    csdr already built - keeping it"
else
  rm -f /usr/bin/csdr /usr/bin/nmux /usr/lib/libcsdr.so   # stale ha7ilm artifacts
  tmp="$(mktemp -d)"
  git clone --depth 1 https://github.com/jketterl/csdr.git "$tmp/csdr"
  cmake -S "$tmp/csdr" -B "$tmp/csdr/build" -DCMAKE_BUILD_TYPE=Release
  cmake --build "$tmp/csdr/build" -j"$(nproc)"
  cmake --install "$tmp/csdr/build"
  ldconfig
  rm -rf "$tmp"
  mkdir -p /usr/local/share && touch /usr/local/share/.csdr-platform-built
fi

echo "==> nrsc5 (build-if-absent)"
if command -v nrsc5 >/dev/null 2>&1; then
  echo "    nrsc5 already present - keeping it"
else
  tmp="$(mktemp -d)"
  git clone --depth 1 https://github.com/theori-io/nrsc5.git "$tmp/nrsc5"
  # System librtlsdr: the bundled rtlsdr ExternalProject fails to produce its
  # static lib on noble (observed 2026-06-10). faad2 stays bundled — nrsc5
  # carries HDC patches the system libfaad lacks. librtlsdr-dev here is NOT a
  # vendor-driver-on-compute violation: it only satisfies nrsc5's unused USB
  # input path; samples still arrive over the network.
  cmake -S "$tmp/nrsc5" -B "$tmp/nrsc5/build" -DCMAKE_BUILD_TYPE=Release \
    -DUSE_SYSTEM_RTLSDR=ON
  cmake --build "$tmp/nrsc5/build" -j"$(nproc)"
  cmake --install "$tmp/nrsc5/build"
  rm -rf "$tmp"
fi

echo "==> SatDump (build-if-absent — long first build)"
if command -v satdump >/dev/null 2>&1; then
  echo "    satdump already present - keeping it"
else
  rm -rf /opt/satdump-src
  git clone --depth 1 https://github.com/SatDump/SatDump.git /opt/satdump-src
  cmake -S /opt/satdump-src -B /opt/satdump-src/build \
    -DCMAKE_BUILD_TYPE=Release -DBUILD_GUI=OFF
  cmake --build /opt/satdump-src/build -j"$(nproc)"
  cmake --install /opt/satdump-src/build
  ldconfig
fi

echo "==> rx_tools (build-if-absent)"
# rx_fm — kept for the toolchain (rx_power etc.), but NO LONGER the FM stream
# client: it mishandles SoapyRemote's small partial reads and garbles remote FM,
# so stream.sh uses wbfm_stream.py instead (see the wbfm branch below). From
# rxseger/rx_tools.
if command -v rx_fm >/dev/null 2>&1; then
  echo "    rx_fm already present - keeping it"
else
  tmp="$(mktemp -d)"
  git clone --depth 1 https://github.com/rxseger/rx_tools.git "$tmp/rx_tools"
  # Patch verbose_setup_stream to read SoapyRemote stream args from $RX_STREAM_ARGS,
  # so the FM stream can force lossless TCP (remote:prot=tcp). Plain-UDP IQ loss
  # garbles analog FM (each dropped datagram = a click; RDS dies) — the reason the
  # 2026-06-13 V2 cutover was rolled back. Harmless for non-remote drivers (the
  # remote: arg is namespaced + ignored).
  python3 - "$tmp/rx_tools/src/convenience/convenience.c" <<'PYEOF'
import sys
p = sys.argv[1]; s = open(p).read()
m = "SoapySDRKwargs stream_args = {0};"
add = ' const char *rx_sa = getenv("RX_STREAM_ARGS"); if (rx_sa && *rx_sa) { stream_args = SoapySDRKwargs_fromString(rx_sa); }'
assert s.count(m) == 1, ("RX_STREAM_ARGS patch marker count", s.count(m))
open(p, "w").write(s.replace(m, m + add, 1))
PYEOF
  cmake -S "$tmp/rx_tools" -B "$tmp/rx_tools/build" -DCMAKE_BUILD_TYPE=Release
  cmake --build "$tmp/rx_tools/build" -j"$(nproc)"
  cmake --install "$tmp/rx_tools/build"
  rm -rf "$tmp"
fi

echo "==> redsea (build-if-absent)"
# RDS decoder for the FM MPX (windytan/redsea, meson build).
if command -v redsea >/dev/null 2>&1; then
  echo "    redsea already present - keeping it"
else
  tmp="$(mktemp -d)"
  git clone --depth 1 https://github.com/windytan/redsea.git "$tmp/redsea"
  meson setup "$tmp/redsea/build" "$tmp/redsea"
  meson compile -C "$tmp/redsea/build"
  meson install -C "$tmp/redsea/build"
  rm -rf "$tmp"
fi

echo "==> radio user + directories"
id -u radio >/dev/null 2>&1 || useradd --system --create-home --home-dir /var/lib/radio-compute --shell /usr/sbin/nologin radio
mkdir -p /etc/radio-compute /opt/radio-compute /var/lib/radio-compute
chown radio:radio /var/lib/radio-compute

echo "==> registry-rendered source envs (ALWAYS rewritten — registry is the source of truth)"
%{ for id, dev in devices ~}
cat > /etc/radio-compute/source-${id}.env <<'EOF'
# platform-managed (registry-rendered) — DO NOT hand-edit; terraform re-apply rewrites.
# Device '${id}' (${dev.role}) served from ${dev.endpoint}, wire ${dev.wire_format}.
# Source contract: pass remote:driver explicitly; set sane gain at connect
# (server default saturates the dx-R2 ADC at 8 Msps).
SOAPY_ARGS=driver=remote,remote=${dev.endpoint},remote:driver=${dev.remote_driver}
SAMPLE_RATE=${dev.sample_rate}
WIRE_FORMAT=${dev.wire_format}
EOF
echo "    wrote /etc/radio-compute/source-${id}.env"
%{ endfor ~}

echo "==> Icecast publish env (written-if-absent; secret, mode 0600)"
if [ -f /etc/radio-compute/icecast.env ]; then
  echo "    icecast.env exists - keeping it"
else
  cat > /etc/radio-compute/icecast.env <<'EOF'
# Rack Icecast source-client credentials (same password as the Pi's Icecast by
# design — cutovers change only the host). Injected via unit EnvironmentFile;
# root-readable only.
ICECAST_HOST=${icecast_host}
ICECAST_PORT=${icecast_port}
ICECAST_SOURCE_PASSWORD=${icecast_source_password}
FM_MOUNT=/fm.mp3
EOF
  chmod 0600 /etc/radio-compute/icecast.env
fi

echo "==> V1 sdr-streams contract (GUI moved 2026-06-10; replaces the interim fm-stream/fm.env contract)"
# The sdr-tuner Flask UI (app code from the radio repo, deployed separately —
# two-cadence rule) speaks the V1 contract unmodified: it writes
# /etc/sdr-streams/active.env and restarts sdr-fm@active. The rack stream.sh
# implements the wbfm/fm branch only; HD (nrsc5) and AM (am_stream.py) are
# radio-repo v2 work and exit 78 (RestartPreventExitStatus — no flap loop).
mkdir -p /etc/sdr-streams /var/lib/sdr-streams /opt/sdr-tuner
chown -R radio:radio /var/lib/sdr-streams /opt/sdr-tuner
# /etc/sdr-streams must be group-writable by radio: the tuner (User=radio) writes
# ui.json (bitrate, site title) there via a temp-file replace (ui_settings.py).
# Root-owned 0755 here blocks every UI settings save with EACCES on ui.tmp.
chown root:radio /etc/sdr-streams
chmod 0775 /etc/sdr-streams

cat > /etc/tmpfiles.d/sdr-streams.conf <<'EOF'
d /run/sdr-streams 0755 radio radio -
EOF
systemd-tmpfiles --create /etc/tmpfiles.d/sdr-streams.conf

if [ -f /etc/sdr-streams/active.env ]; then
  echo "    active.env exists - keeping it"
else
  cat > /etc/sdr-streams/active.env <<'EOF'
MODE=wbfm
FREQ=99.3M
SAMP=200000
GAIN=30
BITRATE=256k
STEREO=1
ANTENNA="Antenna A"
MOUNT=fm.mp3
ICECAST_PASS=${icecast_source_password}
EOF
  chown radio:radio /etc/sdr-streams/active.env
  chmod 0600 /etc/sdr-streams/active.env
fi

if [ -f /etc/sdr-streams/tuner.env ]; then
  echo "    tuner.env exists - keeping it"
else
  cat > /etc/sdr-streams/tuner.env <<'EOF'
# Used by the sdr-tuner UI to rewrite active.env when you tune a station.
ICECAST_PASS=${icecast_source_password}
# wxsat now runs ON the rack (the Meteor scheduler/captures below), so the tuner
# serves /api/wxsat/* from its own /var/lib/sdr-streams/wxsat — no Pi proxy.
EOF
  chown radio:radio /etc/sdr-streams/tuner.env
  chmod 0600 /etc/sdr-streams/tuner.env
fi

# wxsat moved to the rack (2026-06-18 cutover). The tuner must NOT proxy
# /api/wxsat/* to the Pi anymore — comment out any active WXSAT_UPSTREAM left
# from the pre-rack-wxsat setup so radio.rg2.io/wxsat shows THESE captures.
if grep -q '^WXSAT_UPSTREAM=' /etc/sdr-streams/tuner.env; then
  sed -i 's|^WXSAT_UPSTREAM=|#WXSAT_UPSTREAM= (rack serves wxsat locally) |' /etc/sdr-streams/tuner.env
  echo "    tuner.env: disabled WXSAT_UPSTREAM (rack is the wxsat backend)"
fi

if [ -f /opt/sdr-tuner/stream.sh ]; then
  echo "    stream.sh exists - keeping it"
else
  cat > /opt/sdr-tuner/stream.sh <<'EOF'
#!/bin/bash
# RACK variant of the Pi's V1 /opt/sdr-tuner/stream.sh (platform-staged).
# Same active.env contract; FM/wbfm only. Samples come from the remote dx-R2
# (registry-rendered SOAPY_ARGS); audio publishes to the rack Icecast.
set -euo pipefail
source /etc/sdr-streams/active.env
source /etc/radio-compute/source-dx-r2.env

# Force the remote dx-R2 IQ stream onto lossless TCP (wbfm_stream.py reads this;
# SoapyRemote's default UDP firehose drops datagrams). The FM client is
# wbfm_stream.py, NOT rx_fm: rx_fm mishandles SoapyRemote's small partial reads,
# breaking FM demod continuity -> garbled FM + dead RDS. That — not the transport
# — was the real cause of the 2026-06-13 V2 rollback (the same TCP IQ demods
# cleanly with rich RDS through a proper SoapySDR client). Same fix pattern
# am_stream.py already uses for AM.
export RX_STREAM_ARGS=remote:prot=tcp

ICECAST_URL="icecast://source:$ICECAST_PASS@${icecast_host}:${icecast_port}/$MOUNT"

: > /run/sdr-streams/now_playing.json

if [[ "$MODE" == "wbfm" || "$MODE" == "fm" ]]; then
  # wbfm_stream.py reads IQ via SoapySDR directly (channel-select 2-stage; reads
  # FREQ/GAIN/ANTENNA from active.env) and emits 250k s16le MPX. The tee feeds
  # redsea (RDS). STEREO=0 (UI mono toggle) -> a clean mono encode that SKIPS
  # stereo_decode entirely (no noisy 38 kHz L-R subcarrier — best for weak/talk).
  # STEREO=1 -> stereo_decode matrix (hardened carrier recovery: EMA amp + crest
  # clamp + ramped honesty gate). --scale 2.0 / --pilot-floor 0.0015 match the MPX
  # scale + old mono loudness. ffmpeg does per-channel 75us de-emphasis + 15k LP.
  if [[ "$${STEREO:-1}" == "0" ]]; then
    exec bash -c "python3 /opt/sdr-tuner/wbfm_stream.py | \
      tee >(redsea -r 250000 --output json 2>/dev/null | FREQ='$FREQ' /opt/sdr-tuner/rds_watcher.py) | \
      ffmpeg -hide_banner -loglevel warning -f s16le -ar 250000 -ac 1 -i - \
             -af 'aemphasis=mode=reproduction:type=75fm,lowpass=15000' \
             -ar 48000 -ac 1 \
             -c:a libmp3lame -b:a $BITRATE -content_type audio/mpeg \
             -f mp3 '$ICECAST_URL'"
  else
    exec bash -c "python3 /opt/sdr-tuner/wbfm_stream.py | \
      tee >(redsea -r 250000 --output json 2>/dev/null | FREQ='$FREQ' /opt/sdr-tuner/rds_watcher.py) | \
      python3 /opt/sdr-tuner/stereo_decode.py --in-format s16le --out-format f32le --scale 2.0 --pilot-floor 0.0015 | \
      ffmpeg -hide_banner -loglevel warning -f f32le -ar 250000 -ac 2 -i - \
             -af 'aemphasis=mode=reproduction:type=75fm,lowpass=15000,alimiter=level=false' \
             -ar 48000 -ac 2 \
             -c:a libmp3lame -b:a $BITRATE -content_type audio/mpeg \
             -f mp3 '$ICECAST_URL'"
  fi
elif [[ "$MODE" == "am" || "$MODE" == "nfm" ]]; then
  # AM via am_stream.py: reads IQ via SoapySDR (driver=remote, forced onto TCP),
  # narrow 2-stage channel filter + FFT-locked synchronous demod. am_stream picks
  # the device + HW rate from SOURCE in active.env: dx-r2 (2 MHz -> 50k out, ports
  # A/B/C) or hf-plus (the YouLoop on :55002, 768k -> 48k out). Match ffmpeg's
  # input rate to the source. Reads FREQ/GAIN/ANTENNA/SOURCE from active.env. No
  # RDS on AM. ffmpeg trims subsonics, telephone-bands the audio, encodes to mp3.
  AR=50000
  [ "$${SOURCE:-dx-r2}" = "hf-plus" ] && AR=48000
  exec bash -c "python3 /opt/sdr-tuner/am_stream.py | \
    ffmpeg -hide_banner -loglevel warning -f s16le -ar $AR -ac 1 -i - \
           -af 'highpass=f=50,lowpass=f=4800' \
           -ar 48000 -ac 1 \
           -c:a libmp3lame -b:a $BITRATE -content_type audio/mpeg \
           -f mp3 '$ICECAST_URL'"
else
  echo "MODE=$MODE not supported on radio-compute yet (HD is radio-repo v2 work)" >&2
  exit 78
fi
EOF
  chmod +x /opt/sdr-tuner/stream.sh
  chown radio:radio /opt/sdr-tuner/stream.sh
fi

echo "==> sudoers: the tuner UI may control sdr-fm@active"
cat > /etc/sudoers.d/radio-tuner <<'EOF'
radio ALL=(root) NOPASSWD: /usr/bin/systemctl start sdr-fm@active, /usr/bin/systemctl stop sdr-fm@active, /usr/bin/systemctl restart sdr-fm@active, /usr/bin/systemctl start sdr-scan.service, /usr/bin/systemctl stop sdr-scan.service, /usr/bin/systemctl start sdr-am-scan.service, /usr/bin/systemctl stop sdr-am-scan.service, /usr/bin/systemctl start am-compare-a.service, /usr/bin/systemctl stop am-compare-a.service, /usr/bin/systemctl start am-compare-b.service, /usr/bin/systemctl stop am-compare-b.service, /usr/bin/systemctl start fm-watch.timer, /usr/bin/systemctl stop fm-watch.timer
EOF
chmod 0440 /etc/sudoers.d/radio-tuner

echo "==> live A/B comparison units (HF+ vs dx-R2/B -> /am-{a,b}.mp3; app.py /api/abcompare/*)"
if [ -f /opt/sdr-tuner/am-compare.sh ]; then
  echo "    am-compare.sh exists - keeping it"
else
  cat > /opt/sdr-tuner/am-compare.sh <<'EOF'
#!/bin/bash
# Live A/B side: AM-demod one station on one device -> /am-$1.mp3 (a=HF+ YouLoop
# 48k, b=dx-R2 Antenna B 50k). app.py /api/abcompare/* writes the per-side env
# (SOURCE/FREQ/GAIN/ANTENNA) read via AM_ACTIVE_ENV; ICECAST_PASS from active.env.
set -euo pipefail
SIDE="$1"
ENVF="/etc/sdr-streams/am-compare-$SIDE.env"
source <(grep '^ICECAST_PASS=' /etc/sdr-streams/active.env)
SRC=$(grep '^SOURCE=' "$ENVF" | cut -d= -f2 | tr -d '"')
AR=50000; [ "$SRC" = "hf-plus" ] && AR=48000
export AM_ACTIVE_ENV="$ENVF"
exec bash -c "python3 /opt/sdr-tuner/am_stream.py 2>/tmp/am-compare-$SIDE.log | \
  ffmpeg -hide_banner -loglevel error -f s16le -ar $AR -ac 1 -i - \
    -af 'highpass=f=300:p=2,lowpass=f=3800,dynaudnorm=framelen=500:gausssize=11:maxgain=6' \
    -ar 48000 -ac 1 -c:a libmp3lame -b:a 64k -content_type audio/mpeg \
    -f mp3 'icecast://source:$${ICECAST_PASS}@${icecast_host}:${icecast_port}/am-$SIDE.mp3'"
EOF
  chmod +x /opt/sdr-tuner/am-compare.sh
fi
cat > /etc/systemd/system/am-compare-a.service <<'EOF'
[Unit]
Description=AM A/B compare side a (HF+ YouLoop) -> /am-a.mp3
After=network-online.target
[Service]
Type=simple
User=radio
Group=radio
ExecStart=/opt/sdr-tuner/am-compare.sh a
Restart=on-failure
RestartSec=6
EOF
cat > /etc/systemd/system/am-compare-b.service <<'EOF'
[Unit]
Description=AM A/B compare side b (dx-R2 Antenna B, preempts FM) -> /am-b.mp3
Conflicts=sdr-fm@active.service
After=network-online.target
[Service]
Type=simple
User=radio
Group=radio
ExecStart=/opt/sdr-tuner/am-compare.sh b
Restart=on-failure
RestartSec=6
EOF

echo "==> ATC recording: recorder unit + scheduler tick (1-min timer) + retention"
# The app's /api/atc-rec/* write the schedule to here; the tick reconciles it
# against the clock (tune ATC -> record /scanner-atc.mp3 -> back to NOAA -> prune).
# atc-rec-tick.py + atc-record.sh ship with the app payload (deploy.sh).
install -d -o radio -g radio /var/lib/sdr-streams/atc-rec
cat > /etc/systemd/system/atc-record.service <<'EOF'
[Unit]
Description=ATC scheduled recording (icecast mount -> file)
[Service]
Type=simple
User=radio
Group=radio
EnvironmentFile=/var/lib/sdr-streams/atc-rec/record.env
ExecStart=/opt/sdr-tuner/atc-record.sh
Restart=no
EOF
cat > /etc/systemd/system/atc-rec.service <<'EOF'
[Unit]
Description=ATC recording scheduler tick
After=network-online.target
[Service]
Type=oneshot
User=radio
Group=radio
ExecStart=/usr/bin/python3 /opt/sdr-tuner/atc-rec-tick.py
EOF
cat > /etc/systemd/system/atc-rec.timer <<'EOF'
[Unit]
Description=Run the ATC recording scheduler every minute
[Timer]
OnBootSec=45
OnUnitActiveSec=60
AccuracySec=10s
[Install]
WantedBy=timers.target
EOF
# the tick (User=radio) drives the recorder via sudo
cat > /etc/sudoers.d/atc-rec <<'EOF'
radio ALL=(root) NOPASSWD: /usr/bin/systemctl start atc-record.service, /usr/bin/systemctl stop atc-record.service, /usr/bin/systemctl restart atc-record.service
EOF
chmod 0440 /etc/sudoers.d/atc-rec
systemctl daemon-reload
systemctl enable atc-rec.timer >/dev/null 2>&1 || true
systemctl start atc-rec.timer || true

echo "==> systemd units (laid down + reloaded; enable/start is a manual switch step)"
cat > /etc/systemd/system/sdr-fm@.service <<'EOF'
[Unit]
Description=SDR FM stream %i (rack, remote dx-R2)
After=network-online.target
Wants=network-online.target
# Never give up retrying — a transient server-side wedge self-heals on a
# later open; start-limit death just strands the mount.
StartLimitIntervalSec=0

[Service]
Type=simple
User=radio
Group=radio
WorkingDirectory=/opt/sdr-tuner
EnvironmentFile=/etc/sdr-streams/%i.env
# UI tunes restart this unit. The remote sdrplay session wedges if rx_fm is
# killed mid-stream without deactivating its SoapyRemote stream (then every
# reopen fails / decodes garbage until a server-side bounce). SIGINT lets
# rx_fm tear down cleanly; the pre-start sleep lets the server finish
# releasing the device before the reopen.
KillSignal=SIGINT
TimeoutStopSec=15
ExecStartPre=/bin/sleep 2
ExecStart=/opt/sdr-tuner/stream.sh
Restart=always
RestartSec=5
RestartPreventExitStatus=78
[Install]
WantedBy=multi-user.target
EOF

cat > /etc/systemd/system/sdr-tuner.service <<'EOF'
[Unit]
Description=SDR Tuner Web UI (Flask, rack)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=radio
WorkingDirectory=/opt/sdr-tuner
EnvironmentFile=/etc/sdr-streams/tuner.env
ExecStart=/usr/bin/python3 /opt/sdr-tuner/app.py
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

cat > /etc/systemd/system/sdr-captions.service <<'EOF'
[Unit]
Description=SDR caption + lyrics orchestrator (rack)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=radio
WorkingDirectory=/opt/sdr-tuner
EnvironmentFile=/etc/sdr-streams/captions.env
ExecStart=/usr/bin/python3 /opt/sdr-tuner/caption_orchestrator.py
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

# Mount watchdog: ffmpeg can zombie in CLOSE-WAIT when icecast drops the
# source during a restart race (mount 404 while the unit looks active,
# observed 2026-06-10). Two consecutive missing-mount checks → unit restart.
cat > /opt/radio-compute/fm-watch.sh <<'EOF'
#!/usr/bin/env bash
# platform-managed — do not hand-edit; terraform re-apply rewrites.
set -u
STRIKES=/run/fm-watch.strikes
systemctl is-active --quiet sdr-fm@active || { rm -f "$STRIKES"; exit 0; }
# NB: no `|| echo` — fetching an endless stream ALWAYS exits 28 (timeout)
# after -w already printed 200; appending a fallback made "200000" and the
# watchdog restart-looped a healthy stream (bit us 2026-06-10). curl's -w
# prints 000 by itself when the connection truly fails.
code=$(curl -s -m 5 -o /dev/null -w '%%{http_code}' http://${icecast_host}:${icecast_port}/fm.mp3)
if [ "$code" = "200" ]; then rm -f "$STRIKES"; exit 0; fi
n=$(($(cat "$STRIKES" 2>/dev/null || echo 0) + 1))
if [ "$n" -ge 2 ]; then
  echo "fm-watch: mount missing twice (last code $code) - restarting sdr-fm@active"
  rm -f "$STRIKES"
  systemctl restart sdr-fm@active
else
  echo "$n" > "$STRIKES"
fi
EOF
chmod +x /opt/radio-compute/fm-watch.sh

cat > /etc/systemd/system/fm-watch.service <<'EOF'
[Unit]
Description=FM mount watchdog (restart sdr-fm@active if the mount vanishes)

[Service]
Type=oneshot
ExecStart=/opt/radio-compute/fm-watch.sh
EOF

cat > /etc/systemd/system/fm-watch.timer <<'EOF'
[Unit]
Description=Run the FM mount watchdog every minute

[Timer]
OnBootSec=3min
OnUnitActiveSec=1min

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable fm-watch.timer >/dev/null 2>&1 || true
systemctl start fm-watch.timer || true

echo "==> band-scan units (oneshot; the tuner admin page triggers these)"
# fm_scan.py / am_scan.py open the dx-R2 REMOTELY (driver=remote from
# source-dx-r2.env) and write stations.json / stations_am.json. The dx-R2 is
# single-client, so a scan must take it from the live FM: stop fm-watch + FM
# first, restore both after (ExecStopPost runs on success OR failure, so FM
# always comes back even if the scan errors). The +prefix runs those systemctl
# calls as root regardless of User=radio. ~1–2 min FM interruption per FM scan.
cat > /etc/systemd/system/sdr-scan.service <<'EOF'
[Unit]
Description=FM band scan (writes stations.json; interrupts FM for the sweep)
After=network-online.target

[Service]
Type=oneshot
User=radio
Group=radio
TimeoutStartSec=900
ExecStartPre=+/usr/bin/systemctl stop fm-watch.timer
ExecStartPre=+/usr/bin/systemctl stop sdr-fm@active
ExecStart=/usr/bin/python3 /opt/sdr-tuner/fm_scan.py --antennas "Antenna A,Antenna B,Antenna C"
ExecStopPost=+/usr/bin/systemctl start sdr-fm@active
ExecStopPost=+/usr/bin/systemctl start fm-watch.timer
EOF

cat > /etc/systemd/system/sdr-am-scan.service <<'EOF'
[Unit]
Description=AM antenna survey (dx-R2 A/B/C + HF+ YouLoop -> stations_am.json; interrupts FM)
After=network-online.target

[Service]
Type=oneshot
User=radio
Group=radio
TimeoutStartSec=900
ExecStartPre=+/usr/bin/systemctl stop fm-watch.timer
ExecStartPre=+/usr/bin/systemctl stop sdr-fm@active
ExecStart=/bin/bash /opt/sdr-tuner/am_scan_all.sh
ExecStopPost=+/usr/bin/systemctl start sdr-fm@active
ExecStopPost=+/usr/bin/systemctl start fm-watch.timer
EOF
systemctl daemon-reload

echo "==> NOAA Weather Radio (HF+ NBFM -> rack Icecast /wx.mp3)"
# Continuous NBFM demod of the local NWR transmitter (162.550 MHz, validated
# ~60 dB SNR on the HF+ whip 2026-06-17). noaa_stream.py is the wbfm_stream.py
# pattern for narrowband (reads the HF+ over SoapyRemote, prot=tcp stream arg —
# rx_fm mangles SoapyRemote partial reads). Continuous source, so plain ffmpeg
# (no liquidsoap/mksafe). Independent of the dx-R2/FM path — the HF+ is its own
# device. Scripts write-if-absent (hand-tunable); env carries the secret.
if [ -f /opt/sdr-tuner/noaa_stream.py ]; then
  echo "    noaa_stream.py exists - keeping it"
else
  cat > /opt/sdr-tuner/noaa_stream.py <<'PYEOF'
${noaa_stream_py}
PYEOF
  chmod +x /opt/sdr-tuner/noaa_stream.py
fi
if [ -f /etc/radio-compute/wx.env ]; then
  echo "    wx.env exists - keeping it"
else
  cat > /etc/radio-compute/wx.env <<'EOF'
# NOAA Weather Radio (NBFM) on the Airspy HF+ -> rack Icecast /wx.mp3.
# 162.550 MHz = the local Cape Girardeau NWR transmitter. Continuous.
WX_FREQ=162550000
WX_GAIN=32
MOUNT=wx.mp3
ICECAST_HOST=${icecast_host}
ICECAST_PORT=${icecast_port}
ICECAST_PASS=${icecast_source_password}
SOAPY_ARGS=driver=remote,remote=tcp://${pi_host}:55002,remote:driver=airspyhf
EOF
  chmod 0640 /etc/radio-compute/wx.env
  chown root:radio /etc/radio-compute/wx.env 2>/dev/null || true
fi
if [ -f /opt/sdr-tuner/wx-stream.sh ]; then
  echo "    wx-stream.sh exists - keeping it"
else
  cat > /opt/sdr-tuner/wx-stream.sh <<'EOF'
#!/usr/bin/env bash
# NOAA Weather Radio: HF+ NBFM (noaa_stream.py) -> mp3 -> rack Icecast /wx.mp3.
set -euo pipefail
. /etc/radio-compute/wx.env
export SOAPY_ARGS WX_FREQ WX_GAIN
exec bash -c "LD_LIBRARY_PATH=/usr/local/lib python3 /opt/sdr-tuner/noaa_stream.py | \
  ffmpeg -hide_banner -loglevel error -f s16le -ar 16000 -ac 1 -i - \
    -codec:a libmp3lame -b:a 32k -content_type audio/mpeg \
    -ice_name 'NOAA Weather Radio' -f mp3 \
    icecast://source:$ICECAST_PASS@$ICECAST_HOST:$ICECAST_PORT/$MOUNT"
EOF
  chmod +x /opt/sdr-tuner/wx-stream.sh
fi
cat > /etc/systemd/system/wx-stream.service <<'EOF'
[Unit]
Description=NOAA Weather Radio (HF+ NBFM 162.550 -> rack Icecast /wx.mp3)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=radio
Group=radio
ExecStart=/opt/sdr-tuner/wx-stream.sh
Restart=always
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
# The HF+ is its own device (no FM contention), so this one DOES start at
# provision — unlike the dx-R2/FM units.
systemctl enable wx-stream.service >/dev/null 2>&1 || true
systemctl restart wx-stream.service || true

echo "==> NOAA Weather Radio SAME alert decoder + page (wx.rg2.io)"
# Decodes SAME/EAS alerts off /wx.mp3 (ffmpeg | multimon-ng EAS), serves a weather
# page with a live alert banner, and on an alert fires a webhook (Home Assistant)
# + logs it. NPM wx.rg2.io -> this host:8090. Set HA_WEBHOOK_URL in wx-alert.env.
if ! command -v multimon-ng >/dev/null 2>&1; then
  apt-get install -y -qq multimon-ng || echo "    WARN: multimon-ng install failed (SAME decode disabled)"
fi
mkdir -p /var/lib/radio-compute && chown radio:radio /var/lib/radio-compute
if [ -f /opt/sdr-tuner/wx_alert.py ]; then
  echo "    wx_alert.py exists - keeping it"
else
  cat > /opt/sdr-tuner/wx_alert.py <<'PYEOF'
${wx_alert_py}
PYEOF
  chmod +x /opt/sdr-tuner/wx_alert.py
fi
if [ -f /etc/radio-compute/wx-alert.env ]; then
  echo "    wx-alert.env exists - keeping it"
else
  cat > /etc/radio-compute/wx-alert.env <<'EOF'
# wx.rg2.io page + SAME alert decoder. Set HA_WEBHOOK_URL to a Home Assistant
# webhook (e.g. https://ha.rg2.io/api/webhook/<id>) to announce alerts on house
# speakers / push. Empty = banner + log only.
WX_PORT=8090
WX_DECODE_URL=http://192.168.6.82:8000/wx.mp3
WX_PUBLIC_URL=https://icecast.rg2.io/wx.mp3
HA_WEBHOOK_URL=
EOF
  chmod 0640 /etc/radio-compute/wx-alert.env
  chown root:radio /etc/radio-compute/wx-alert.env 2>/dev/null || true
fi
cat > /etc/systemd/system/wx-alert.service <<'EOF'
[Unit]
Description=NOAA Weather Radio page + SAME alert decoder (wx.rg2.io)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=radio
Group=radio
EnvironmentFile=/etc/radio-compute/wx-alert.env
ExecStart=/usr/bin/python3 /opt/sdr-tuner/wx_alert.py
Restart=always
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable wx-alert.service >/dev/null 2>&1 || true
systemctl restart wx-alert.service || true

%{ if wxsat_enabled ~}
echo "==> Weather-sat (Meteor LRPT) rack decoder — records p24's rtl_tcp -> SatDump"
# The Nooelec (Meteor V-dipole) lives on the outdoor ADS-B Pi (p24) and is served
# over rtl_tcp; this rack backend records a pass to CU8 and decodes it with the
# local SatDump (build above). No SDR contention (dedicated dongle) -> no FM
# stop/restart, no listener check (unlike the Pi's wxsat). Code is provisioner-
# owned (overwritten from the repo); wxsat.env is keep-if-absent (hand-tunable).

# pyorbital is pip-only on noble (no apt package). numpy/scipy/requests come from
# apt (installed above). Guard so re-provisions don't reinstall.
if ! python3 -c 'import pyorbital' >/dev/null 2>&1; then
  command -v pip3 >/dev/null 2>&1 || apt-get install -y python3-pip >/dev/null 2>&1 || true
  echo "    installing pyorbital (pip)"
  pip3 install --break-system-packages pyorbital >/dev/null 2>&1 || \
    echo "    WARN: pyorbital install failed — scheduler will not predict passes"
fi

install -d -m 0755 /opt/wxsat
# SatDump 2.0-alpha (built above) resolves its plugin .so dir as ./plugins
# relative to cwd — the build bakes no absolute path. Give it a working dir whose
# ./plugins points at the real install so the capture script can `cd` here.
install -d -o radio -g radio -m 0755 /opt/wxsat/sdwd
ln -sfn /usr/lib/satdump/plugins /opt/wxsat/sdwd/plugins
# celestrak.org is unreachable from here (same as the Pi); SatDump's TLE
# auto-update otherwise blocks ~134s per run. Fast-fail it (we seed TLEs in the
# capture script). Idempotent.
if ! grep -q 'celestrak.org' /etc/hosts; then
  echo '127.0.0.1 celestrak.org celestrak.com' >> /etc/hosts
  echo "    /etc/hosts: celestrak fast-fail added (SatDump TLE auto-update)"
fi
cat > /opt/wxsat/wxsat_record_rtltcp.py <<'PYEOF'
${wxsat_record_py}
PYEOF
cat > /opt/wxsat/wxsat_predict.py <<'PYEOF'
${wxsat_predict_py}
PYEOF
cat > /opt/wxsat/wxsat_scheduler.py <<'PYEOF'
${wxsat_scheduler_py}
PYEOF
cat > /opt/wxsat/wxsat_capture_rack.sh <<'EOF'
${wxsat_capture_sh}
EOF
chmod +x /opt/wxsat/wxsat_record_rtltcp.py /opt/wxsat/wxsat_scheduler.py /opt/wxsat/wxsat_capture_rack.sh

# Storage lives on the rack: products + the captures index + the TLE cache.
install -d -o radio -g radio -m 0755 /var/lib/sdr-streams/wxsat /var/lib/sdr-streams/wxsat/tle

# wxsat.env — keep-if-absent (operator tunes gain/DRY_RUN). DRY_RUN=1 is the safe
# default: predicts + lists passes but never records, until the operator flips it.
if [ -f /etc/radio-compute/wxsat.env ]; then
  echo "    wxsat.env exists - keeping it"
else
  cat > /etc/radio-compute/wxsat.env <<EOF
# Weather-sat (Meteor-M2 LRPT) capture on the rack, off p24's rtl_tcp Nooelec.
# systemd EnvironmentFile: '#' only at line start; no inline comments after values.
DRY_RUN=1
WXSAT_RTLTCP_HOST=${wxsat_rtltcp_host}
WXSAT_RTLTCP_PORT=${wxsat_rtltcp_port}
WXSAT_FREQ_HZ=${wxsat_freq_hz}
WXSAT_SAMPLERATE=${wxsat_samplerate}
# Tenths of dB; empty = AGC. KEEP LOW: a powered Sawbird+ NOAA LNA (~40 dB,
# filtered) is upstream, so the RTL must run near-minimum — it provides the gain.
# 40 dB RTL gain STACKED on the LNA clipped ~19% of samples (overload, mean|IQ|
# ~110) and killed the LRPT decode 2026-06-18. 7.2 dB gives clean IQ (0% clip,
# mean|IQ|~40). Don't raise without re-checking clip% at 137.9.
WXSAT_GAIN_TENTHS=72
FREQ_MHZ=137.9
MIN_ELEV_DEG=20
PREDICT_HOURS=48
M2_4_ENABLED=1
M2_3_ENABLED=0
LAT=37.31
LON=-89.55
ALT_KM=0.1
LRPT_PIPELINE=meteor_m2-x_lrpt
WXSAT_BB_FORMAT=u8
WXSAT_KEEP_IQ_ON_FAIL=1
WXSAT_KEEP_IQ_ALWAYS=0
WXSAT_MIN_FREE_GB=2
AOS_BUFFER_S=45
POST_LOS_S=15
REFRESH_INTERVAL_S=1800
EOF
  chmod 0644 /etc/radio-compute/wxsat.env
fi

cat > /etc/systemd/system/wxsat-scheduler.service <<'EOF'
[Unit]
Description=Weather-sat (Meteor LRPT) scheduler — rack decode of p24 rtl_tcp
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=radio
Group=radio
Environment=HOME=/var/lib/sdr-streams/wxsat
EnvironmentFile=/etc/radio-compute/wxsat.env
ExecStart=/usr/bin/python3 /opt/wxsat/wxsat_scheduler.py
Restart=always
RestartSec=15s

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
# Safe to run pre-cutover: with DRY_RUN=1 it only predicts + writes passes.json.
systemctl enable wxsat-scheduler.service >/dev/null 2>&1 || true
systemctl restart wxsat-scheduler.service || true

# GALLERY: the tuner.env block above already disabled WXSAT_UPSTREAM, so
# radio.rg2.io/wxsat serves THESE rack captures (upcoming passes show at once;
# images fill in as passes decode). Re-point at the Pi only for a rollback.
echo "    wxsat-scheduler: $(systemctl is-active wxsat-scheduler.service 2>/dev/null) (DRY_RUN gates real captures; gallery serves rack-local /var/lib/sdr-streams/wxsat)"
%{ endif ~}

echo "==> provisioning complete (toolchain staged; no units, nothing started)"
echo "    csdr=$(command -v csdr || echo missing) nrsc5=$(command -v nrsc5 || echo missing) satdump=$(command -v satdump || echo missing)"
%{ for id, dev in devices ~}
echo "    device '${id}' -> ${dev.endpoint} (remote:driver=${dev.remote_driver}, ${dev.wire_format} @ ${dev.sample_rate})"
%{ endfor ~}
