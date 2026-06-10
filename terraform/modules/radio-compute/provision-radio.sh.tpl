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
  soapysdr-tools soapysdr-module-remote python3-soapysdr \
  ffmpeg sox python3-venv python3-numpy python3-scipy \
  git cmake build-essential pkg-config curl \
  autoconf automake libtool \
  libusb-1.0-0-dev libudev-dev librtlsdr-dev \
  libfftw3-dev libsamplerate0-dev libsndfile1-dev libao-dev \
  libpng-dev libtiff-dev libjemalloc-dev libcurl4-openssl-dev \
  zlib1g-dev libzstd-dev libvolk-dev nlohmann-json3-dev libnng-dev libsqlite3-dev

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

echo "==> provisioning complete (toolchain staged; no units, nothing started)"
echo "    csdr=$(command -v csdr || echo missing) nrsc5=$(command -v nrsc5 || echo missing) satdump=$(command -v satdump || echo missing)"
%{ for id, dev in devices ~}
echo "    device '${id}' -> ${dev.endpoint} (remote:driver=${dev.remote_driver}, ${dev.wire_format} @ ${dev.sample_rate})"
%{ endfor ~}
