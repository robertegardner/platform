#!/usr/bin/env bash
# weather-compute provisioner — rack LXC (unprivileged). Preps the box to run
# weewx 5 for the Davis Vantage station (read over the Pi Zero's ser2net bridge
# at ${weather_host}:${ser2net_port}), serve Belchertown via nginx, and upload to
# WU/CWOP/PWSweather/AWEKAS + MQTT. The actual weewx CONFIG, SKINS, extensions and
# the 0.4 GB archive DB are MIGRATED from the live Zero at cutover (single-master
# Davis console — can't double-read), so weewx is installed but left STOPPED here.
#
# Re-run safe. NB: remote-exec runs WITHOUT `set -e`.
set -uo pipefail

echo "==> weather-compute provisioning on $(hostname) — weewx 5 + nginx (read bridge ${weather_host}:${ser2net_port})"

# --- 1) Base packages (the Ubuntu LXC template ships no curl/wget/gnupg) ------
apt-get update -qq
apt-get install -y wget gnupg nginx rsync sqlite3 python3-paho-mqtt >/dev/null 2>&1 \
  || echo "    WARN: base package install failed"

# --- 2) weewx 5 from the weewx apt repo --------------------------------------
if command -v weewxd >/dev/null 2>&1 || dpkg -l weewx >/dev/null 2>&1; then
  echo "    weewx present: $(weewxd --version 2>/dev/null)"
else
  echo "    adding the weewx apt repo + installing weewx 5"
  wget -qO - https://weewx.com/keys.html 2>/dev/null | grep -oE "[A-F0-9]{40}" >/dev/null 2>&1 || true
  # weewx 5 python3 repo (arch=all). Key + list per weewx.com/docs install.
  wget -qO /etc/apt/trusted.gpg.d/weewx.gpg https://weewx.com/apt/weewx-python3.gpg 2>/dev/null \
    || echo "    WARN: weewx key fetch failed"
  echo "deb [arch=all] https://weewx.com/apt/python3 buster main" > /etc/apt/sources.list.d/weewx.list
  apt-get update -qq
  # Non-interactive: take the package defaults (Simulator); the REAL config is
  # migrated from the Zero at cutover, so these defaults are just a placeholder.
  DEBIAN_FRONTEND=noninteractive apt-get install -y weewx >/dev/null 2>&1 \
    || echo "    WARN: weewx install failed — check the repo/suite at apply time"
fi

# --- 3) Leave weewx STOPPED until the Zero's config/DB are migrated -----------
# (A running weewx here would just spin the Simulator and could write junk into
# the archive before the real DB lands.)
systemctl stop weewx 2>/dev/null || true
systemctl disable weewx 2>/dev/null || true
echo "    weewx: installed, left stopped (migrate config/skins/DB at cutover, then enable+start)"

# --- 4) nginx — serve the weewx HTML root ------------------------------------
# Belchertown writes its site under HTML_ROOT (/var/www/html/weewx on the Zero);
# weewx.conf migrated at cutover sets HTML_ROOT. Point nginx's default site at it.
install -d -m 0755 /var/www/html/weewx
if ! grep -s "weather-compute managed" /etc/nginx/sites-available/default >/dev/null 2>&1; then
  cat > /etc/nginx/sites-available/default <<'EOF'
# weather-compute managed — serve the weewx/Belchertown site at /.
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    root /var/www/html/weewx;
    index index.html;
    server_name _;
    location / { try_files $uri $uri/ =404; }
}
EOF
  echo "    wrote nginx default site (root /var/www/html/weewx)"
fi
systemctl enable nginx >/dev/null 2>&1 || true
systemctl restart nginx || echo "    WARN: nginx restart failed"

echo "==> weather-compute prepped. CUTOVER (manual, coordinated): migrate /etc/weewx"
echo "    (conf+skins+bin/user) + /var/lib/weewx/weewx.sdb from ${weather_host}, set"
echo "    [Vantage] type=ethernet host=${weather_host} port=${ser2net_port}, enable+start weewx."
