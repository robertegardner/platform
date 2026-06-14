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
EOF
  chown radio:radio /etc/sdr-streams/tuner.env
  chmod 0600 /etc/sdr-streams/tuner.env
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
  # wbfm_stream.py (deployed from the radio repo alongside am_stream.py) reads IQ
  # via SoapySDR directly and emits the same 250k s16le MPX rx_fm did, so the
  # tee->redsea(RDS)+ffmpeg chain below is unchanged. It reads device/tune from
  # active.env + source-dx-r2.env itself.
  exec bash -c "python3 /opt/sdr-tuner/wbfm_stream.py | \
    tee >(redsea -r 250000 --output json 2>/dev/null | FREQ='$FREQ' /opt/sdr-tuner/rds_watcher.py) | \
    ffmpeg -hide_banner -loglevel warning -f s16le -ar 250000 -ac 1 -i - \
           -af 'aemphasis=mode=reproduction:type=75fm,lowpass=15000' \
           -ar 48000 -ac 1 \
           -c:a libmp3lame -b:a $BITRATE -content_type audio/mpeg \
           -f mp3 '$ICECAST_URL'"
else
  echo "MODE=$MODE not supported on radio-compute yet (HD/AM are radio-repo v2 work)" >&2
  exit 78
fi
EOF
  chmod +x /opt/sdr-tuner/stream.sh
  chown radio:radio /opt/sdr-tuner/stream.sh
fi

echo "==> sudoers: the tuner UI may control sdr-fm@active"
cat > /etc/sudoers.d/radio-tuner <<'EOF'
radio ALL=(root) NOPASSWD: /usr/bin/systemctl start sdr-fm@active, /usr/bin/systemctl stop sdr-fm@active, /usr/bin/systemctl restart sdr-fm@active
EOF
chmod 0440 /etc/sudoers.d/radio-tuner

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

echo "==> provisioning complete (toolchain staged; no units, nothing started)"
echo "    csdr=$(command -v csdr || echo missing) nrsc5=$(command -v nrsc5 || echo missing) satdump=$(command -v satdump || echo missing)"
%{ for id, dev in devices ~}
echo "    device '${id}' -> ${dev.endpoint} (remote:driver=${dev.remote_driver}, ${dev.wire_format} @ ${dev.sample_rate})"
%{ endfor ~}
