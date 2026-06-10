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
  ffmpeg sox python3-venv python3-numpy python3-scipy \
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
# rx_fm — the V1 FM demodulator, SoapySDR-based, so the identical Pi chain
# runs here against driver=remote. From rxseger/rx_tools.
if command -v rx_fm >/dev/null 2>&1; then
  echo "    rx_fm already present - keeping it"
else
  tmp="$(mktemp -d)"
  git clone --depth 1 https://github.com/rxseger/rx_tools.git "$tmp/rx_tools"
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

echo "==> FM chain (written-if-absent — hand-tuned, do not clobber)"
# Interim V1-parity chain: the exact Pi stream.sh FM pipeline (rx_fm | tee
# redsea | ffmpeg) against the remote dx-R2. The multistation stereo mux
# (radio repo v2) replaces this; HD (nrsc5) and AM (am_stream.py) modes stay
# Pi-repo app work for now.
if [ -f /etc/radio-compute/fm.env ]; then
  echo "    fm.env exists - keeping it"
else
  cat > /etc/radio-compute/fm.env <<'EOF'
# FM station config (hand-tunable; matches the V1 active.env at cutover).
FM_SOURCE=dx-r2
FREQ=99.3M
GAIN=30
BITRATE=256k
ANTENNA='Antenna A'
EOF
fi

if [ -f /opt/radio-compute/run-fm.sh ]; then
  echo "    run-fm.sh exists - keeping it"
else
  mkdir -p /opt/radio-compute
  cat > /opt/radio-compute/run-fm.sh <<'EOF'
#!/usr/bin/env bash
# FM + RDS -> rack Icecast. V1-parity port of the Pi's stream.sh fm branch:
# rx_fm demodulates the MPX at 250k (sdrplay decimates server-side, ~1 MB/s
# on the wire); redsea decodes RDS from the same MPX; ffmpeg de-emphasizes,
# lowpasses and encodes. Icecast creds arrive via the unit EnvironmentFile.
set -euo pipefail
. /etc/radio-compute/fm.env
. "/etc/radio-compute/source-$FM_SOURCE.env"

# RDS side-branch keeps only the latest group as JSON (no rds_watcher.py here
# yet — the tuner UI integration is radio-repo v2 work).
exec bash -c "rx_fm -d '$SOAPY_ARGS' -a '$ANTENNA' -M fm -l 0 -A std -s 250000 -g $GAIN -f $FREQ -F 9 - | \
  tee >(redsea -r 250000 --output json 2>/dev/null | while IFS= read -r line; do printf '%s\n' \"\$line\" > /var/lib/radio-compute/rds-latest.json; done) | \
  ffmpeg -hide_banner -loglevel warning -f s16le -ar 250000 -ac 1 -i - \
         -af 'aemphasis=mode=reproduction:type=75fm,lowpass=15000' \
         -ar 48000 -ac 1 \
         -c:a libmp3lame -b:a $BITRATE -content_type audio/mpeg \
         -f mp3 'icecast://source:$ICECAST_SOURCE_PASSWORD@$ICECAST_HOST:$ICECAST_PORT$FM_MOUNT'"
EOF
  chmod +x /opt/radio-compute/run-fm.sh
fi

echo "==> systemd unit (laid down + reloaded; enable/start happens at the radio cutover)"
cat > /etc/systemd/system/fm-stream.service <<'EOF'
[Unit]
Description=FM + RDS stream: remote dx-R2 -> rack Icecast /fm.mp3
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=radio
Group=radio
WorkingDirectory=/var/lib/radio-compute
EnvironmentFile=/etc/radio-compute/icecast.env
ExecStart=/opt/radio-compute/run-fm.sh
Restart=always
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload

echo "==> provisioning complete (toolchain staged; no units, nothing started)"
echo "    csdr=$(command -v csdr || echo missing) nrsc5=$(command -v nrsc5 || echo missing) satdump=$(command -v satdump || echo missing)"
%{ for id, dev in devices ~}
echo "    device '${id}' -> ${dev.endpoint} (remote:driver=${dev.remote_driver}, ${dev.wire_format} @ ${dev.sample_rate})"
%{ endfor ~}
