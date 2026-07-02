#!/usr/bin/env bash
# pi-wxsat provisioner — goes.srvr (the dedicated GOES decode Pi), bare metal.
#
# Brings up the Meteor dongle (tuned Meteor antenna + powered LNA) as a
# localhost rtl_tcp source AND the Pi-LOCAL capture stack (section 5): this Pi
# sits on the Garage UDB wireless bridge, so capture must not depend on the
# network — wxsat-scheduler records locally into /var/lib/wxsat/captures and
# the rack's wxsat-sync (.84) pulls completed dirs to decode/index/notify.
#
# HARD RULE: never disturb the GOES downlink. goes.service is serial-pinned to
# the SMArTee (47360874); we select the Nooelec (serial 22012952) STRICTLY by its
# unique serial and hard-fail rather than ever fall back to device 0. Enumeration
# is not stable (the Nooelec has come up index 0, the SMArTee index 1).
#
# Everything is install-if-absent / re-run safe. NB: remote-exec runs WITHOUT
# `set -e` — chained `&& rm` at the call site guards real failures; here we keep
# going on best-effort steps and only the rtl_tcp unit's own start gates health.
set -uo pipefail

SERIAL="${serial}"
BIND="${bind_addr}"
PORT="${port}"
GAIN="${gain}"

echo "==> pi-wxsat provisioning on $(hostname) — Nooelec serial=$${SERIAL} rtl_tcp ${bind_addr}:${port}"

# --- 1) rtl-sdr tools (rtl_tcp / rtl_eeprom / rtl_test) ----------------------
# The GOES Pi already uses librtlsdr for goes.service, so these are almost
# certainly present. Install only if something is missing (never reinstall).
need_pkg=0
for b in rtl_tcp rtl_eeprom rtl_test; do
  command -v "$b" >/dev/null 2>&1 || need_pkg=1
done
if [ "$need_pkg" = "1" ]; then
  echo "    installing rtl-sdr (a tool was missing)"
  apt-get update -qq && apt-get install -y rtl-sdr >/dev/null 2>&1 || echo "    WARN: rtl-sdr install failed"
else
  echo "    rtl-sdr tools present"
fi

# --- 2) Blacklist the kernel DVB driver -------------------------------------
# A freshly-plugged RTL gets seized by dvb_usb_rtl28xxu. Blacklist so librtlsdr
# keeps it. Safe for goes.service — it already uses librtlsdr/usbfs, not these
# modules. NB: pi-goes writes this SAME file (identical DVB blacklist); this
# block is keep-if-absent, so whichever module runs first wins and the other
# no-ops — the effect is the same.
BL=/etc/modprobe.d/blacklist-rtlsdr-dvb.conf
if [ ! -f "$BL" ]; then
  cat > "$BL" <<'EOF'
# platform-managed (pi-wxsat): keep RTL-SDR dongles off the DVB-T kernel driver
# so librtlsdr/rtl_tcp can claim the Nooelec. goes.service already uses
# librtlsdr; this only stops the kernel from grabbing a fresh dongle.
blacklist dvb_usb_rtl28xxu
blacklist rtl2832
blacklist rtl2832_sdr
blacklist rtl2830
EOF
  echo "    wrote $BL"
  # Best-effort unload of anything already bound (no-op if not loaded / in use).
  for m in rtl2832_sdr dvb_usb_rtl28xxu rtl2832 rtl2830; do modprobe -r "$m" 2>/dev/null || true; done
else
  echo "    $BL present"
fi

# --- 2b) usbfs buffer for multi-dongle USB ----------------------------------
# The GOES Pi now streams 2 RTL dongles (the GOES SMArTee @2.4 Msps + the Nooelec
# @250k). A small usbfs pool (default 16 MB) causes rtl_tcp "Failed to submit
# transfer" + client resets. Raise it persistently (tmpfiles.d applies it at boot,
# before the SDR services) AND now — 1000 MB is ample for both. (USB power/signal
# -71 enumerate drops are a SEPARATE hardware issue — needs a powered hub.)
US=/etc/tmpfiles.d/usbfs-sdr.conf
if ! grep -qs usbfs_memory_mb "$US"; then
  echo "w /sys/module/usbcore/parameters/usbfs_memory_mb - - - - 1000" > "$US"
  echo "    wrote $US (usbfs_memory_mb=1000)"
fi
systemd-tmpfiles --create "$US" 2>/dev/null || \
  echo 1000 > /sys/module/usbcore/parameters/usbfs_memory_mb 2>/dev/null || true
echo "    usbfs_memory_mb=$(cat /sys/module/usbcore/parameters/usbfs_memory_mb 2>/dev/null)"

# --- 2c) USB current budget (Pi 5) ------------------------------------------
# Two RTL dongles (the GOES SMArTee @2.4 Msps + this Nooelec) exceed the Pi 5's
# DEFAULT 600 mA total-USB cap -> over-current trips that silently kill the GOES
# stream ("cb transfer status: 1", SatDump stalls while systemd still shows
# active). Raise the cap to 1.6 A. NB: takes effect only after a REBOOT, and
# asserts the supply can source it — this Pi runs on a PoE HAT; a >=25W/802.3at
# HAT has the headroom (verified throttled=0x0 with BOTH dongles streaming
# 2026-07-01). If it's an 802.3af/15W HAT, use a powered USB hub instead.
CT=/boot/firmware/config.txt
if [ -f "$CT" ] && ! grep -q usb_max_current_enable "$CT"; then
  printf '\n# platform (pi-wxsat): full USB current (1.6A) for dual RTL (GOES SMArTee + Meteor Nooelec). Reboot to apply.\nusb_max_current_enable=1\n' >> "$CT"
  echo "    added usb_max_current_enable=1 to $CT (REBOOT required to apply)"
else
  echo "    usb_max_current_enable already set (or $CT absent) — leaving it"
fi

# --- 3) (No EEPROM reflash) -------------------------------------------------
# The Nooelec NESDR SMArt ships a FACTORY-UNIQUE serial (22012952), distinct
# from the GOES SMArTee (47360874), so there is no collision and nothing to
# reflash — selection is by that serial below. (We avoid EEPROM writes entirely;
# this dongle has shown flaky tuner comms historically.)

# --- 4) rtl_tcp serving wrapper + env + unit --------------------------------
# rtl_tcp -d takes a device INDEX (not a serial), and index order is not stable
# on a multi-dongle host (the Nooelec has come up index 0, the SMArTee index 1).
# The wrapper resolves the index from the unique serial and HARD-FAILS if absent
# — never serves an arbitrary dongle (would risk the GOES SMArTee).
install -d -m 0755 /etc/wxsat
if [ -f /etc/wxsat/rtltcp.env ]; then
  echo "    /etc/wxsat/rtltcp.env exists - keeping it"
else
  cat > /etc/wxsat/rtltcp.env <<EOF
# pi-wxsat rtl_tcp source (Meteor dongle). Tuning (freq/rate/gain) is driven by
# the CLIENT over the rtl_tcp protocol — the Pi-local capture client sets
# 137.9 MHz + sample rate per pass. WXSAT_GAIN here is the default tuner gain
# (tenths of dB; empty = auto/AGC). Selection is by serial, never index.
WXSAT_SERIAL=${serial}
WXSAT_BIND=${bind_addr}
WXSAT_PORT=${port}
WXSAT_GAIN=${gain}
EOF
  echo "    wrote /etc/wxsat/rtltcp.env"
fi

cat > /usr/local/sbin/wxsat-rtltcp.sh <<'EOF'
#!/usr/bin/env bash
# Serve the Nooelec (selected by unique serial) over rtl_tcp on the LAN.
set -uo pipefail
. /etc/wxsat/rtltcp.env
idx="$(timeout 5 rtl_test 2>&1 | grep "SN: $${WXSAT_SERIAL}" | grep -oE '^[[:space:]]*[0-9]+:' | tr -dc '0-9' | head -c3)"
if [ -z "$${idx}" ]; then
  echo "wxsat-rtltcp: no dongle with serial '$${WXSAT_SERIAL}' — refusing to serve (would risk an ADS-B dongle)" >&2
  exit 1
fi
echo "wxsat-rtltcp: serving Nooelec serial=$${WXSAT_SERIAL} (index $${idx}) on $${WXSAT_BIND}:$${WXSAT_PORT}"
exec rtl_tcp -d "$${idx}" -a "$${WXSAT_BIND}" -p "$${WXSAT_PORT}" $${WXSAT_GAIN:+-g $${WXSAT_GAIN}}
EOF
chmod +x /usr/local/sbin/wxsat-rtltcp.sh

cat > /etc/systemd/system/wxsat-rtltcp.service <<'EOF'
[Unit]
Description=wxsat rtl_tcp source (Nooelec Meteor V-dipole) -> rack SatDump
Documentation=https://github.com/robertegardner/platform
After=network-online.target
Wants=network-online.target

[Service]
ExecStart=/usr/local/sbin/wxsat-rtltcp.sh
Restart=always
RestartSec=10
# Soft-fail if the Nooelec isn't enumerated yet — keep retrying without spamming.
StartLimitIntervalSec=0
Nice=5

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable wxsat-rtltcp.service >/dev/null 2>&1 || true
# Restart (not enable --now) so a config rewrite reloads. A missing/unenumerated
# Nooelec just leaves the unit retrying — it never touches an ADS-B dongle.
systemctl restart wxsat-rtltcp.service || true
echo "    wxsat-rtltcp: $(systemctl is-active wxsat-rtltcp.service 2>/dev/null)"

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
