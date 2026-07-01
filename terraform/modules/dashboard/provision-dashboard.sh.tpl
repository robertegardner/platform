#!/usr/bin/env bash
# dashboard provisioner — rack LXC (unprivileged). Serves the unified platform
# landing page (home.rg2.io): a stdlib-Python http.server that polls every
# service's status API server-side and renders one MD3 tile per domain.
#
# Re-run safe / write-if-absent. NB: remote-exec runs WITHOUT `set -e`.
set -uo pipefail

echo "==> dashboard provisioning on $(hostname) — port ${dashboard_port}"

# --- 1) Packages (stdlib only — just need python3) --------------------------
if ! command -v python3 >/dev/null 2>&1; then
  apt-get update -qq
  apt-get install -y python3 >/dev/null 2>&1 || echo "    WARN: apt install python3 failed"
fi

# --- 2) App (provisioner-managed — hashed trigger re-pushes it) -------------
install -d -m 0755 /opt/dashboard /etc/dashboard
cp /tmp/dashboard.py /opt/dashboard/dashboard.py
chmod 0755 /opt/dashboard/dashboard.py

# --- 3) Config (write-if-absent so on-box tuning survives a re-apply) -------
if [ ! -f /etc/dashboard/dashboard.env ]; then
  cat > /etc/dashboard/dashboard.env <<EOF
# dashboard config. Edit + 'systemctl restart dashboard' to apply.
DASH_PORT=${dashboard_port}
DASH_TITLE=${site_title}
DASH_POLL_INTERVAL=15
# Backend status APIs the aggregator polls (HTTP, Server VLAN).
DASH_RADIO_BASE=${radio_base}
DASH_SCANNER_BASE=${scanner_base}
DASH_GOES_BASE=${goes_base}
DASH_WX_BASE=${wx_base}
DASH_WEATHER_BASE=${weather_base}
DASH_ADSB_BASE=${adsb_base}
DASH_ICECAST_BASE=${icecast_base}
DASH_COMICS_BASE=${comics_base}
# Public "open" targets (dive-in links) + the inline audio mount (all TLS).
DASH_OPEN_RADIO=https://radio.rg2.io/dash
DASH_OPEN_SCANNER=https://ems.rg2.io
DASH_OPEN_GOES=https://goes.rg2.io
DASH_OPEN_GOES_AIM=http://192.168.6.134:8091/
DASH_OPEN_WEATHER=https://w.rg2.io
DASH_OPEN_ADSB=https://adsb.rg2.io
DASH_OPEN_METEOR=https://radio.rg2.io/wxsat
DASH_OPEN_ICECAST=https://icecast.rg2.io
DASH_ICECAST_PUBLIC=https://icecast.rg2.io
DASH_FM_AUDIO_URL=https://icecast.rg2.io/fm.mp3
EOF
  echo "    wrote /etc/dashboard/dashboard.env"
else
  echo "    /etc/dashboard/dashboard.env present — keeping on-box tuning"
fi

# --- 4) systemd unit --------------------------------------------------------
cat > /etc/systemd/system/dashboard.service <<'EOF'
[Unit]
Description=Unified platform dashboard (home.rg2.io)
After=network-online.target
Wants=network-online.target
[Service]
Type=simple
EnvironmentFile=/etc/dashboard/dashboard.env
ExecStart=/usr/bin/python3 /opt/dashboard/dashboard.py
Restart=always
RestartSec=5
[Install]
WantedBy=multi-user.target
EOF

# --- 5) Enable + (re)start --------------------------------------------------
systemctl daemon-reload
systemctl enable dashboard.service >/dev/null 2>&1 || true
systemctl restart dashboard.service || echo "    WARN: dashboard did not start"

echo "    dashboard: $(systemctl is-active dashboard.service 2>/dev/null)"
echo "==> dashboard done. Browse: http://$(hostname -I | awk '{print $$1}'):${dashboard_port}/"
