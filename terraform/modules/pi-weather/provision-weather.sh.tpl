#!/usr/bin/env bash
# pi-weather provisioner — weather2 (Pi Zero 2 W), the thin Davis-console bridge.
#
# Re-serves the Davis Vantage console (Bluetooth rfcomm → /dev/rfcomm0) as a raw
# serial-over-TCP port via ser2net, so the rack weewx (weather-compute LXC) reads
# it with the Vantage driver in `type = ethernet` mode. The heavy weewx/report/web
# load leaves the flaky Zero.
#
# SINGLE-MASTER: the Davis console allows only one reader, so this can't run
# alongside the local weewx. `cutover=false` (default) installs the bridge IDLE
# (local weewx keeps the console); `cutover=true` performs the coordinated switch.
# weather2 is a LIVE node — install-if-absent, re-run safe. NB: remote-exec runs
# WITHOUT `set -e`.
set -uo pipefail

CONSOLE_MAC="${console_mac}"
PORT="${ser2net_port}"
echo "==> pi-weather provisioning on $(hostname) — Davis bridge (rfcomm $${CONSOLE_MAC} -> ser2net :$${PORT}), cutover=${cutover}"

# --- 1) ser2net (apt) --------------------------------------------------------
if command -v ser2net >/dev/null 2>&1; then
  echo "    ser2net present: $(ser2net -v 2>&1 | head -1)"
else
  apt-get update -qq && apt-get install -y ser2net >/dev/null 2>&1 || echo "    WARN: ser2net install failed"
fi

# --- 2) ser2net config: /dev/rfcomm0 -> raw TCP :PORT (Vantage 19200 8N1) -----
# ser2net v4 (YAML). If this Pi runs v3, the config path/format differs
# (/etc/ser2net.conf line format) — checked at apply.
if [ -d /etc/ser2net ] || ser2net -v 2>&1 | grep -qE "version 4"; then
  cat > /etc/ser2net.yaml <<EOF
%YAML 1.1
---
define: &banner ""
connection: &davis-vantage
  accepter: tcp,0.0.0.0,${ser2net_port}
  enable: on
  connector: serialdev,/dev/rfcomm0,19200n81,local
  options:
    kickolduser: true
    max-connections: 2
EOF
  echo "    wrote /etc/ser2net.yaml (v4)"
else
  echo "${ser2net_port}:raw:0:/dev/rfcomm0:19200 8DATABITS NONE 1STOPBIT" > /etc/ser2net.conf
  echo "    wrote /etc/ser2net.conf (v3)"
fi

# --- 3) Hardened rfcomm-bind unit (replaces the rc.local one-shot; rebinds) ---
# rc.local currently does `rfcomm connect hci0 <MAC> &` once at boot — no rebind
# on drop (a flakiness source). This unit blocks on the connection and
# Restart=always re-binds. NOT activated until cutover (would fight rc.local's
# binding + the local weewx).
cat > /etc/systemd/system/rfcomm-davis.service <<EOF
[Unit]
Description=Bind the Davis Vantage console over Bluetooth rfcomm
After=bluetooth.target
Wants=bluetooth.service
[Service]
ExecStart=/usr/bin/rfcomm connect hci0 ${console_mac} 1
Restart=always
RestartSec=10
[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload

%{ if cutover ~}
# ===================== CUTOVER (cutover=true) =====================
# The rack weewx is ready on the bridge — hand the console over.
echo "    CUTOVER: stopping local weewx + web servers, starting ser2net"
# 1) Free the console + retire the on-Pi load.
for u in weewx nginx apache2 lighttpd; do
  if systemctl is-enabled "$u" >/dev/null 2>&1 || systemctl is-active "$u" >/dev/null 2>&1; then
    systemctl stop "$u" 2>/dev/null || true
    systemctl disable "$u" 2>/dev/null || true
    echo "      retired $u"
  fi
done
# 2) Prevent rc.local's one-shot rfcomm from double-binding on the next boot, and
#    take over with the hardened unit (effective next boot; we do NOT re-bind live
#    to avoid a Bluetooth re-pair during cutover — rc.local's link stays up now).
if grep -qs "rfcomm connect" /etc/rc.local; then
  sed -i 's/^\([^#].*rfcomm connect.*\)$/# (pi-weather) replaced by rfcomm-davis.service: \1/' /etc/rc.local
  echo "      commented the rc.local rfcomm line"
fi
systemctl enable rfcomm-davis.service >/dev/null 2>&1 || true
# 3) Start ser2net on the currently-bound /dev/rfcomm0 (now free of weewx).
systemctl enable ser2net >/dev/null 2>&1 || true
systemctl restart ser2net || echo "      WARN: ser2net did not start"
echo "    ser2net: $(systemctl is-active ser2net 2>/dev/null) on :${ser2net_port}"
%{ else ~}
# ===================== STAGED (cutover=false) =====================
# Install only — leave the local weewx owning the console. ser2net + the rfcomm
# unit are written but NOT started (they'd fight the live weewx for the console).
systemctl stop ser2net 2>/dev/null || true
systemctl disable ser2net 2>/dev/null || true
echo "    bridge STAGED (idle). Flip cutover=true to switch the console to the rack."
%{ endif ~}

echo "==> pi-weather done (cutover=${cutover})."
