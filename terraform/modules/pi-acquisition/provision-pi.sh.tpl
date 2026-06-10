#!/usr/bin/env bash
# Rendered by Terraform (templatefile) and executed as root on the Pi
# (radio.srvr) via `sudo` over SSH from thebeast. Acquisition tier: brings up one
# SoapyRemote source server per PRESENT device from the device registry.
#
# RE-RUN SAFE / build-if-absent. Does NOT rebuild SoapySDR or SoapySDRPlay3
# (already built from source on the Pi). Does NOT enable or start any source
# unit — that would auto-claim a single-client device (the dx-R2) at boot against
# the live radio (sdr-fm@active). Source servers are started by hand inside an
# attended window only. See CLAUDE.md / the Phase 0 build prompt.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

echo "==> SoapyRemote server (build-if-absent)"
if command -v SoapySDRServer >/dev/null 2>&1; then
  echo "    SoapySDRServer already present - keeping it"
else
  apt-get update -qq || true
  # Debian ships the SoapyRemote server + client module in soapysdr-module-remote.
  if apt-get install -y -qq soapysdr-module-remote soapysdr-tools; then
    echo "    installed soapysdr-module-remote via apt"
  fi
  if ! command -v SoapySDRServer >/dev/null 2>&1; then
    echo "    apt did not provide SoapySDRServer - building SoapyRemote from source"
    apt-get install -y -qq git cmake g++ make libsoapysdr-dev pkg-config
    tmp="$(mktemp -d)"
    git clone --depth 1 https://github.com/pothosware/SoapyRemote.git "$tmp/SoapyRemote"
    cmake -S "$tmp/SoapyRemote" -B "$tmp/SoapyRemote/build" -DCMAKE_BUILD_TYPE=Release
    cmake --build "$tmp/SoapyRemote/build" -j"$(nproc)"
    cmake --install "$tmp/SoapyRemote/build"
    rm -rf "$tmp"
  fi
fi
command -v SoapySDRServer >/dev/null 2>&1 || { echo "FATAL: SoapySDRServer still missing"; exit 1; }
# Absolute path for the unit's ExecStart — apt installs to /usr/bin, the source
# build to /usr/local/bin; detect whichever is present.
SERVER_BIN="$(command -v SoapySDRServer)"
echo "    SoapySDRServer at $${SERVER_BIN}"

echo "==> socket buffers for SoapyRemote streaming"
# SoapyRemote installs a sysctl drop recommending 100 MB socket buffers, but a
# file landing post-boot is never applied — the Pi sat at the 4 MB default and
# 8 Msps CS16 streams stalled after ~6 s (proven in the Phase 0B tuning window;
# raising these fixed it). Persist to /etc/sysctl.d and apply now.
cat > /etc/sysctl.d/10-sdr-source.conf <<'EOF'
# SoapyRemote source servers: large socket buffers for high-rate IQ streaming.
net.core.rmem_max=104857600
net.core.wmem_max=104857600
EOF
/sbin/sysctl -p /etc/sysctl.d/10-sdr-source.conf

echo "==> SDRplay loader path fix"
# SoapySDRPlay3 lives in /usr/local/lib and needs libsdrplay_api.so.3 (also in
# /usr/local/lib), which is not on this host's default loader path. Without this,
# the source server cannot dlopen the SDRplay module and the dx-R2 won't open.
echo "/usr/local/lib" > /etc/ld.so.conf.d/usrlocal-sdrplay.conf
ldconfig

echo "==> SoapyRTLSDR module (build-if-absent)"
# Needed to serve the RTL2838 (interim scanner source) over SoapyRemote. The
# Pi's SoapySDR is built from source in /usr/local, so the apt module may not
# match its ABI/module path — build SoapyRTLSDR from source against it if the
# factory isn't visible. librtlsdr itself comes from apt.
# grep without -q: under pipefail, -q's early exit can SIGPIPE the producer
# and fail the pipeline on a genuine match.
if LD_LIBRARY_PATH=/usr/local/lib SoapySDRUtil --info 2>/dev/null | grep -i rtlsdr >/dev/null; then
  echo "    rtlsdr factory already visible - keeping it"
else
  apt-get update -qq || true
  apt-get install -y -qq librtlsdr-dev rtl-sdr git cmake g++ make pkg-config
  tmp="$(mktemp -d)"
  git clone --depth 1 https://github.com/pothosware/SoapyRTLSDR.git "$tmp/SoapyRTLSDR"
  cmake -S "$tmp/SoapyRTLSDR" -B "$tmp/SoapyRTLSDR/build" -DCMAKE_BUILD_TYPE=Release
  cmake --build "$tmp/SoapyRTLSDR/build" -j"$(nproc)"
  cmake --install "$tmp/SoapyRTLSDR/build"
  rm -rf "$tmp"
  ldconfig
  LD_LIBRARY_PATH=/usr/local/lib SoapySDRUtil --info 2>/dev/null | grep -i rtlsdr >/dev/null \
    || { echo "FATAL: rtlsdr factory still not visible after build"; exit 1; }
fi

echo "==> Per-device source environment files"
mkdir -p /etc/sdr-source
%{ for id, dev in devices ~}
if [ -f /etc/sdr-source/${id}.env ]; then
  echo "    /etc/sdr-source/${id}.env exists - keeping it"
else
  cat > /etc/sdr-source/${id}.env <<'EOF'
# Source server config for device '${id}' (rendered from the device registry).
SOAPY_PORT=${dev.port}
SOAPY_DEVICE_ARGS=${dev.soapy_args}
EOF
  echo "    wrote /etc/sdr-source/${id}.env (port ${dev.port})"
fi
%{ endfor ~}

echo "==> sdr-source@.service unit"
# %i is the device id; SOAPY_PORT comes from /etc/sdr-source/%i.env. With a
# single present device a lone server is fine (per-device isolation-by-serial is
# a later decision per the architecture doc).
cat > /etc/systemd/system/sdr-source@.service <<'EOF'
[Unit]
Description=SoapyRemote source server for %i (acquisition tier)
After=network-online.target sdrplay.service
Wants=network-online.target

[Service]
Type=simple
EnvironmentFile=/etc/sdr-source/%i.env
Environment=LD_LIBRARY_PATH=/usr/local/lib
ExecStart=__SERVER_BIN__ --bind=0.0.0.0:$${SOAPY_PORT}
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF

# Substitute the detected server path (use # as delimiter — path has slashes).
sed -i "s#__SERVER_BIN__#$${SERVER_BIN}#" /etc/systemd/system/sdr-source@.service

systemctl daemon-reload

# Intentionally NOT enabling/starting any sdr-source@ instance: the dx-R2 is
# single-client and the live radio claims it at boot. Start a source server by
# hand only after stopping sdr-fm@active, in an attended window.
#
# Exception (by hand, at cutover — not here): sdr-source@rtl-2838 MAY be
# enabled at boot once the Pi's EMS job is retired (SCHEDULER_EMS_DEFAULT=false)
# — its only client is the rack scanner-compute, so there is no contention.
echo "==> provisioning complete (units laid down, not started)"
%{ for id, dev in devices ~}
echo "    device '${id}' -> sdr-source@${id} on port ${dev.port} (${dev.soapy_args})"
%{ endfor ~}
