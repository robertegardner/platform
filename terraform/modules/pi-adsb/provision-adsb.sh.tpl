#!/usr/bin/env bash
# pi-adsb provisioner — p24.srvr, bare metal (standalone outdoor ADS-B Pi).
#
# Turns p24 into a DECODE-ONLY platform node: readsb (1090ES, replacing the aged
# dump1090-mutability) + dump978-fa (978 UAT, kept) serving Beast/SBS/raw on the
# LAN. The rack adsb-feeder LXC (ultrafeeder) does all aggregation + feeding now,
# so the on-Pi feeders (piaware, adsbexchange-*) and local maps are retired here.
#
# p24 is a LIVE production feeder. Install-if-absent / re-run safe. The readsb
# config is marker-guarded so hand-tuned gain survives. SDRs are selected BY
# SERIAL — p24's enumeration order is reversed (index 0 = the 978 dongle), so
# index-based selection would cross-grab the wrong RTL. NB: remote-exec runs
# WITHOUT `set -e`.
set -uo pipefail

SERIAL_1090="${serial_1090}"
SERIAL_978="${serial_978}"
echo "==> pi-adsb provisioning on $(hostname) — readsb 1090=$${SERIAL_1090}, dump978 978=$${SERIAL_978}"

# --- 1) DVB blacklist + usbfs (keep-if-absent; both already present on p24) ---
BL=/etc/modprobe.d/blacklist-rtlsdr-dvb.conf
if [ ! -f "$BL" ]; then
  cat > "$BL" <<'EOF'
# platform-managed (pi-adsb): keep the RTL-SDRs off the DVB-T kernel driver.
blacklist dvb_usb_rtl28xxu
blacklist rtl2832
blacklist rtl2832_sdr
blacklist rtl2830
EOF
  echo "    wrote $BL"
fi
US=/etc/tmpfiles.d/usbfs-sdr.conf
if ! grep -s usbfs_memory_mb "$US" >/dev/null; then
  echo "w /sys/module/usbcore/parameters/usbfs_memory_mb - - - - 1000" > "$US"
  systemd-tmpfiles --create "$US" 2>/dev/null || echo 1000 > /sys/module/usbcore/parameters/usbfs_memory_mb 2>/dev/null || true
  echo "    wrote $US (usbfs_memory_mb=1000)"
fi

# --- 2) Install readsb if absent (wiedehopf script — long; guarded) ----------
if command -v readsb >/dev/null 2>&1; then
  echo "    readsb present: $(command -v readsb)"
else
  echo "    installing readsb (wiedehopf script)"
  bash -c "$(wget -nv -O - https://github.com/wiedehopf/adsb-scripts/raw/master/readsb-install.sh)" >/dev/null 2>&1 \
    || echo "    WARN: readsb install failed"
fi

# --- 3) readsb config — 1090ES on SERIAL_1090, Beast/SBS/raw on the LAN -------
# Marker-guarded: keep a hand-edited config (e.g. tuned gain), else write ours.
RC=/etc/default/readsb
if grep -s "platform-managed" "$RC" >/dev/null; then
  echo "    $RC platform-managed present — keeping it (hand-tunable gain)"
else
  cat > "$RC" <<EOF
# platform-managed (pi-adsb) — readsb 1090ES decode-only; the rack ingests Beast.
RECEIVER_OPTIONS="--device-type rtlsdr --device ${serial_1090} --gain ${gain_1090} --ppm 0"
DECODER_OPTIONS="--max-range 360 --write-state-only-on-exit"
NET_OPTIONS="--net --net-heartbeat 60 --net-ro-size 1280 --net-ro-interval 0.05 --net-ri-port 30001 --net-ro-port 30002 --net-sbs-port 30003 --net-bi-port 30004,30104 --net-bo-port 30005"
JSON_OPTIONS="--json-location-accuracy 2"
EOF
  echo "    wrote $RC (gain=${gain_1090})"
fi

# --- 4) Cut 1090 over: stop the old decoder, then start readsb ---------------
# dump1090-mutability holds SERIAL_1090 + ports 30002-30005. It MUST stop before
# readsb can bind them / claim the SDR. Brief (~seconds) 1090 gap; the rack's
# net-connector reconnects automatically. 978 (dump978-fa) is untouched.
if systemctl is-enabled dump1090-mutability >/dev/null 2>&1 || systemctl is-active dump1090-mutability >/dev/null 2>&1; then
  systemctl stop dump1090-mutability 2>/dev/null || true
  systemctl disable dump1090-mutability 2>/dev/null || true
  echo "    retired dump1090-mutability"
fi
systemctl enable readsb >/dev/null 2>&1 || true
systemctl restart readsb || echo "    WARN: readsb did not start"
echo "    readsb: $(systemctl is-active readsb 2>/dev/null)"

# --- 5) dump978-fa stays (978 UAT, raw :30978) ------------------------------
systemctl enable dump978-fa >/dev/null 2>&1 || true
echo "    dump978-fa: $(systemctl is-active dump978-fa 2>/dev/null)"

# --- 6) Retire the on-Pi feeders + local maps (the rack owns these now) ------
for u in piaware adsbexchange-feed adsbexchange-mlat adsbexchange-stats tar1090-adsbx skyaware978; do
  if systemctl is-enabled "$u" >/dev/null 2>&1 || systemctl is-active "$u" >/dev/null 2>&1; then
    systemctl stop "$u" 2>/dev/null || true
    systemctl disable "$u" 2>/dev/null || true
    echo "    retired $u"
  fi
done

echo "==> pi-adsb done. p24 is decode-only (readsb 1090 + dump978-fa 978 -> rack)."
