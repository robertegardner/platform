#!/usr/bin/env bash
# pi-goes provisioner — goes.srvr, bare metal (Pi 5).
#
# GOES-19 HRIT reception + LIVE SatDump decode. Unlike the other tier-1 Pis this
# one decodes (GOES is geostationary/continuous — there is no pass to capture and
# decode offline), so SatDump's `live goes_hrit` runs here and the rack only
# rsync-pulls the small image products.
#
# Re-run safe / install-if-absent. The canonical goes.service is KEEP-IF-ABSENT:
# the gain/frequency are hand-tuned for the dish + Sawbird GOES LNA, so a re-apply
# must never clobber a working command. NB: remote-exec runs WITHOUT `set -e`.
set -uo pipefail

OUTPUT_DIR="${output_dir}"
PRUNE_HOURS="${prune_hours}"
RUN_USER="${ssh_user}"

echo "==> pi-goes provisioning on $(hostname) — GOES-19 HRIT live decode, output=$${OUTPUT_DIR}"

# --- 1) Blacklist the kernel DVB driver -------------------------------------
# Keep the kernel's dvb_usb_rtl28xxu off the Nooelec SmArTee so librtlsdr/SatDump
# can claim it. Single-dongle host, so this is unambiguous and safe.
BL=/etc/modprobe.d/blacklist-rtlsdr-dvb.conf
if [ ! -f "$BL" ]; then
  cat > "$BL" <<'EOF'
# platform-managed (pi-goes): keep the RTL-SDR off the DVB-T kernel driver so
# librtlsdr/SatDump can claim it for the GOES downlink.
blacklist dvb_usb_rtl28xxu
blacklist rtl2832
blacklist rtl2832_sdr
blacklist rtl2830
EOF
  echo "    wrote $BL"
  for m in rtl2832_sdr dvb_usb_rtl28xxu rtl2832 rtl2830; do modprobe -r "$m" 2>/dev/null || true; done
else
  echo "    $BL present"
fi

# --- 2) SatDump present (do NOT build — it's a long source build) -----------
if command -v satdump >/dev/null 2>&1; then
  echo "    satdump present: $(command -v satdump)"
else
  echo "    WARN: satdump not found — install it manually; goes.service will fail until then"
fi

# --- 3) Reconcile to ONE canonical SatDump unit -----------------------------
# An abandoned earlier attempt (satdump-geos.service: writes goes_data, --offline,
# gain 45) lingers disabled. Remove it so there's a single source of truth.
if systemctl list-unit-files satdump-geos.service >/dev/null 2>&1; then
  systemctl stop satdump-geos.service 2>/dev/null || true
  systemctl disable satdump-geos.service 2>/dev/null || true
  rm -f /etc/systemd/system/satdump-geos.service
  echo "    removed leftover satdump-geos.service"
fi

# --- 3a) Serial-pin wrapper -------------------------------------------------
# goes.service must bind the GOES SMArTee (not a second RTL like the Meteor
# Nooelec). SatDump's RTL selector is --source_id <librtlsdr index>; index order
# is NOT stable with two identical RTL2838s, so resolve it from the unique serial
# at each start and HARD-FAIL rather than grab index 0. (Same pattern as
# pi-wxsat's wxsat-rtltcp.sh.)
install -d /etc/goes
cat > /etc/goes/pin.env <<EOF
GOES_SERIAL=${goes_serial}
EOF
cat > /usr/local/sbin/goes-satdump.sh <<'EOF'
#!/bin/bash
# platform-managed (pi-goes): pin SatDump to the GOES SMArTee by serial.
set -u
. /etc/goes/pin.env 2>/dev/null || true
: "$${GOES_SERIAL:?GOES_SERIAL unset}"
idx="$(timeout 5 rtl_test 2>&1 | grep "SN: $${GOES_SERIAL}" | grep -oE '^[[:space:]]*[0-9]+:' | tr -dc '0-9' | head -c3 || true)"
if [ -z "$${idx}" ]; then
  echo "goes-satdump: no RTL with serial $${GOES_SERIAL} — refusing to start (would risk grabbing the Meteor Nooelec)" >&2
  exit 1
fi
echo "goes-satdump: SMArTee serial=$${GOES_SERIAL} -> librtlsdr index $${idx}"
# SatDump 2.0-alpha requires --opt=value for extra options; a space-separated
# "--source_id $${idx}" corrupts the parser ("Could not find a handler for
# source type : rtlsdr"). Equals syntax is mandatory here.
exec /usr/bin/satdump "$@" --source_id=$${idx}
EOF
chmod +x /usr/local/sbin/goes-satdump.sh
echo "    wrote /usr/local/sbin/goes-satdump.sh (serial-pin, GOES_SERIAL=${goes_serial})"

# goes.service: KEEP-IF-ABSENT. The live command's gain/frequency are hand-tuned
# for this dish + Sawbird GOES LNA; never overwrite a working unit. The default
# written below (only on a fresh Pi) mirrors the validated live command. If a
# fresh write ever decodes 0 CADU / NOSYNC, the Sawbird LNA likely needs the
# SmArTee bias-tee powered (add a `bias=1`/external power) — same failure mode as
# an unpowered LNA elsewhere in the platform.
GS=/etc/systemd/system/goes.service
if [ -f "$GS" ]; then
  echo "    $GS present — keeping the hand-tuned unit"
  # Idempotent pin: route the existing hand-tuned ExecStart through the wrapper
  # (which appends --source_id). Only touches the binary path; freq/gain/rate
  # are preserved. Marker = the wrapper path already being present.
  if grep 'ExecStart=/usr/bin/satdump ' "$GS" >/dev/null 2>&1; then
    sed -i 's#ExecStart=/usr/bin/satdump #ExecStart=/usr/local/sbin/goes-satdump.sh #' "$GS"
    systemctl daemon-reload
    echo "    patched goes.service ExecStart -> serial-pin wrapper"
  else
    echo "    goes.service ExecStart already pinned (or custom) — left as-is"
  fi
else
  cat > "$GS" <<EOF
[Unit]
Description=SatDump GOES-19 HRIT live decode
Documentation=https://github.com/robertegardner/platform
After=network-online.target
Wants=network-online.target

[Service]
User=$${RUN_USER}
ExecStartPre=/bin/mkdir -p ${output_dir}
ExecStart=/usr/local/sbin/goes-satdump.sh live goes_hrit ${output_dir} --source rtlsdr \
  --samplerate ${samplerate} --frequency ${frequency_hz} --gain ${gain} \
  --http_server 0.0.0.0:8080
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF
  echo "    wrote default $GS (fresh install, serial-pinned)"
fi
systemctl daemon-reload
systemctl enable goes.service >/dev/null 2>&1 || true
systemctl restart goes.service || echo "    WARN: goes.service did not start (SDR detached?)"
echo "    goes.service: $(systemctl is-active goes.service 2>/dev/null)"

# --- 4) Local prune timer ---------------------------------------------------
# The SD card is small (~11 GB free) and goes_output grows ~7 GB/day. Keep only
# the last PRUNE_HOURS so the card never fills. INVARIANT: the rack pulls every
# ~60s (goes-pull.timer on the LXC) << this retention, so nothing is lost.
cat > /usr/local/sbin/goes-prune.sh <<EOF
#!/usr/bin/env bash
# platform-managed (pi-goes): drop goes_output older than the retention window.
set -uo pipefail
OUT="${output_dir}"
MIN=\$(( ${prune_hours} * 60 ))
# Timestamped capture dirs: IMAGES/<sat>/<sector>/<YYYY-MM-DD_HH-MM-SS>/
[ -d "\$OUT/IMAGES" ] && find "\$OUT/IMAGES" -mindepth 3 -maxdepth 3 -type d -mmin +\$MIN -exec rm -rf {} + 2>/dev/null
# EMWIN / L2 / Admin files age out by mtime.
for sub in EMWIN L2 "Admin Messages"; do
  [ -d "\$OUT/\$sub" ] && find "\$OUT/\$sub" -type f -mmin +\$MIN -delete 2>/dev/null
done
exit 0
EOF
chmod +x /usr/local/sbin/goes-prune.sh

cat > /etc/systemd/system/goes-prune.service <<'EOF'
[Unit]
Description=Prune old GOES products from the Pi's SD card
[Service]
Type=oneshot
ExecStart=/usr/local/sbin/goes-prune.sh
EOF

cat > /etc/systemd/system/goes-prune.timer <<'EOF'
[Unit]
Description=Run goes-prune periodically
[Timer]
OnBootSec=10min
OnUnitActiveSec=30min
AccuracySec=1min
[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable goes-prune.timer >/dev/null 2>&1 || true
systemctl restart goes-prune.timer || true
echo "    goes-prune.timer: $(systemctl is-active goes-prune.timer 2>/dev/null) (retention $${PRUNE_HOURS}h)"

# --- 5) Dish-aiming tool (goes-aim) -----------------------------------------
# Serves the look angles (az/el to the GOES bird from the station) + a live
# peaking meter off SatDump's HTTP API, on :8091. Provisioner-managed.
install -d -m 0755 /opt/goes-aim
cp /tmp/goes_aim.py /opt/goes-aim/goes_aim.py
chmod 0755 /opt/goes-aim/goes_aim.py
cat > /etc/systemd/system/goes-aim.service <<'EOF'
[Unit]
Description=GOES dish-aiming tool (look angles + live SatDump peaking)
After=network-online.target
[Service]
ExecStart=/usr/bin/python3 /opt/goes-aim/goes_aim.py
Restart=always
RestartSec=5
[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable goes-aim >/dev/null 2>&1 || true
systemctl restart goes-aim || echo "    WARN: goes-aim did not start"
echo "    goes-aim: $(systemctl is-active goes-aim 2>/dev/null) on :8091"

# --- 6) goes-watch watchdog (self-heal a SILENT SatDump stall) --------------
# SatDump can keep its process alive (systemd 'active', Restart=always never
# fires) while the RTL-SDR sample stream has stalled — no new products land for
# many minutes (seen live 2026-06-29: dark ~50 min). If nothing under the output
# tree changed in $${STALE_MIN} minutes, restart the decoder. A $${GRACE_MIN}-minute
# grace window after each (re)start prevents restart loops. Same pattern as the
# FM fm-watch.timer. Mirrors goes-prune (write-then-enable+restart).
cat > /usr/local/sbin/goes-watch.sh <<EOF
#!/usr/bin/env bash
# platform-managed (pi-goes): restart goes.service on a silent SatDump stall.
set -uo pipefail
OUT="${output_dir}"
STALE_MIN=${watch_stale_min}
GRACE_MIN=${watch_grace_min}

# Only police a service that's meant to be running (leave failed/stopped alone).
[ "\$(systemctl is-active goes.service)" = "active" ] || exit 0

# Grace: skip if goes.service (re)started within the grace window.
ae=\$(systemctl show goes.service -p ActiveEnterTimestamp --value 2>/dev/null)
if [ -n "\$ae" ]; then
  st=\$(date -d "\$ae" +%s 2>/dev/null || echo 0)
  [ "\$st" -gt 0 ] && [ \$(( \$(date +%s) - st )) -lt \$(( GRACE_MIN * 60 )) ] && exit 0
fi

# Healthy if ANY product changed within the stale window (stops at first hit).
[ -n "\$(find "\$OUT" -type f -mmin -\$STALE_MIN -print -quit 2>/dev/null)" ] && exit 0

echo "goes-watch: no new products in \$STALE_MIN min — SatDump stalled; restarting goes.service"
systemctl restart goes.service
EOF
chmod +x /usr/local/sbin/goes-watch.sh

cat > /etc/systemd/system/goes-watch.service <<'EOF'
[Unit]
Description=Watchdog — restart SatDump if GOES products go silent
After=goes.service
[Service]
Type=oneshot
ExecStart=/usr/local/sbin/goes-watch.sh
EOF

cat > /etc/systemd/system/goes-watch.timer <<'EOF'
[Unit]
Description=Run goes-watch periodically
[Timer]
OnBootSec=5min
OnUnitActiveSec=5min
AccuracySec=30s
[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable goes-watch.timer >/dev/null 2>&1 || true
systemctl restart goes-watch.timer || true
echo "    goes-watch.timer: $(systemctl is-active goes-watch.timer 2>/dev/null) (stale ${watch_stale_min}m, grace ${watch_grace_min}m)"

echo "==> pi-goes done."
