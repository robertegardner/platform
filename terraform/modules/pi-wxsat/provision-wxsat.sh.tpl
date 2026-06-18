#!/usr/bin/env bash
# pi-wxsat provisioner — p24.srvr (the OUTDOOR ADS-B Pi), bare metal.
#
# Brings up the Nooelec RTL2838 (Meteor V-dipole) as an rtl_tcp source for the
# rack's SatDump decoder. p24's job here is THIN: serve the dedicated Nooelec on
# the LAN; all decode + storage happen on radio-compute (.84).
#
# HARD RULE: never disturb the two live ADS-B dongles (1090 @ serial 00001090,
# UAT 978 @ serial 00000001). We select the Nooelec STRICTLY by its unique
# reprogrammed serial and hard-fail rather than ever fall back to device 0.
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
# p24 already feeds ADS-B via librtlsdr, so these are almost certainly present.
# Install only if something is missing (never reinstall over a working feeder).
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
# A freshly-plugged RTL gets seized by dvb_usb_rtl28xxu (seen flapping on p24:
# rtl2832_sdr -> swradio0 -> disconnect). Blacklist so librtlsdr keeps it. Safe
# for the running feeders — they already use librtlsdr/usbfs, not these modules.
BL=/etc/modprobe.d/blacklist-rtlsdr-dvb.conf
if [ ! -f "$BL" ]; then
  cat > "$BL" <<'EOF'
# platform-managed (pi-wxsat): keep RTL-SDR dongles off the DVB-T kernel driver
# so librtlsdr/rtl_tcp can claim the Nooelec. The ADS-B feeders already use
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

# --- 3) (No EEPROM reflash) -------------------------------------------------
# The Nooelec NESDR SMArt ships a FACTORY-UNIQUE serial (22012952), distinct
# from p24's two ADS-B dongles (00000001 UAT, 00001090 1090), so there is no
# collision and nothing to reflash — selection is by that serial below. (Earlier
# reflash attempts also showed this Pi's USB resets are flaky; we avoid EEPROM
# writes entirely.)

# --- 4) rtl_tcp serving wrapper + env + unit --------------------------------
# rtl_tcp -d takes a device INDEX (not a serial), and index order is not stable
# on a multi-dongle host. The wrapper resolves the index from the unique serial
# and HARD-FAILS if absent — never serves an arbitrary (possibly ADS-B) dongle.
install -d -m 0755 /etc/wxsat
if [ -f /etc/wxsat/rtltcp.env ]; then
  echo "    /etc/wxsat/rtltcp.env exists - keeping it"
else
  cat > /etc/wxsat/rtltcp.env <<EOF
# pi-wxsat rtl_tcp source (Nooelec Meteor V-dipole). Tuning (freq/rate/gain) is
# driven by the CLIENT over the rtl_tcp protocol — the rack's SatDump sets
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
echo "==> pi-wxsat done. wxsat-rtltcp: $(systemctl is-active wxsat-rtltcp.service 2>/dev/null)"
