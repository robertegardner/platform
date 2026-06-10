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
# op25 trunk receiver — Cape County MOSWIN (P25 Phase II), remote source via
# SoapyRemote. Hand-tunable (gain, fine-tune, flags) — provisioning writes this
# only if absent. Audio goes out as PCM over UDP to ems-stream.service.
set -euo pipefail
. /etc/scanner-compute/scanner.env
. "/etc/scanner-compute/source-$ACTIVE_SOURCE.env"

# Source contract #4: the client sets sane gain at connect (server-side default
# saturates). The R820T exposes a single "TUNER" gain element (0-49.6 dB) —
# wrong element names are silently ignored and leave the dongle deaf
# (proven on air 2026-06-10). Tune via the op25 http terminal on :8080.
GAINS="TUNER:38"

cd /opt/op25/op25/gr-op25_repeater/apps
exec ./rx.py --nocrypt --args "$OSMOSDR_ARGS" --gains "$GAINS" \
  -S "$SAMPLE_RATE" -q 0 -T /opt/scanner-compute/moswin-trunk.tsv \
  -2 -V -U -v 1 -l 'http:0.0.0.0:8080' \
  2>>/var/lib/scanner-compute/op25-stderr.log
EOF
  chmod +x /opt/scanner-compute/run-op25.sh
fi

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

echo "==> systemd units (laid down + reloaded; enable/start happens at cutover)"
cat > /etc/systemd/system/op25-ems.service <<'EOF'
[Unit]
Description=op25 P25 trunk receiver (Cape County MOSWIN, remote source)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=scanner
Group=scanner
WorkingDirectory=/var/lib/scanner-compute
ExecStart=/opt/scanner-compute/run-op25.sh
Restart=on-failure
RestartSec=10s

[Install]
WantedBy=multi-user.target
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

systemctl daemon-reload

echo "==> provisioning complete (units laid down, not started — cutover enables them)"
%{ for id, dev in devices ~}
echo "    device '${id}' -> ${dev.endpoint} (remote:driver=${dev.remote_driver}, ${dev.wire_format} @ ${dev.sample_rate})"
%{ endfor ~}
