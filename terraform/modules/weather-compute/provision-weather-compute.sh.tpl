#!/usr/bin/env bash
# weather-compute provisioner — rack LXC (unprivileged). The REPORT-ONLY half of
# the weather2 fold: weewx COLLECTION stays on the Pi Zero (Vantage DMPAFT only
# works over the local BT serial). The Zero replicates its archive DB here via
# Litestream (SFTP push -> ${replica_path}); this box RESTORES a faithful copy on
# a timer and runs `weectl report run` (Belchertown + Seasons) + serves it via
# nginx. It NEVER runs weewxd (so it can never double-collect or double-upload —
# weewx.service is masked).
#
# Re-run safe. NB: remote-exec runs WITHOUT `set -e`.
set -uo pipefail

REPLICA="${replica_path}"
DB="${db_path}"
LS_VER="${litestream_version}"
echo "==> weather-compute on $(hostname) — report-only weewx (restore $${REPLICA} -> $${DB}), nginx"

# --- 1) Base packages (the Ubuntu LXC template ships no curl/wget/gnupg) ------
apt-get update -qq
apt-get install -y wget gnupg dirmngr nginx rsync sqlite3 python3-paho-mqtt python3-setuptools >/dev/null 2>&1 \
  || echo "    WARN: base package install failed"

# --- 2) weewx 5 from the weewx apt repo (for the skins + weectl report run) ---
if command -v weewxd >/dev/null 2>&1 || dpkg -l weewx >/dev/null 2>&1; then
  echo "    weewx present: $(weewxd --version 2>/dev/null)"
else
  echo "    adding the weewx apt repo + installing weewx 5"
  gpg --no-default-keyring --keyring /tmp/wx-kr.gpg --keyserver keyserver.ubuntu.com \
    --recv-keys B7D370EC17FC079E >/dev/null 2>&1 \
    && gpg --no-default-keyring --keyring /tmp/wx-kr.gpg --export > /etc/apt/trusted.gpg.d/weewx.gpg \
    || echo "    WARN: weewx key import failed"
  rm -f /tmp/wx-kr.gpg
  echo "deb [arch=all] https://weewx.com/apt/python3 buster main" > /etc/apt/sources.list.d/weewx.list
  apt-get update -qq
  DEBIAN_FRONTEND=noninteractive apt-get install -y weewx >/dev/null 2>&1 \
    || echo "    WARN: weewx install failed — check the repo/suite at apply time"
fi

# --- 3) NEVER run weewxd here — mask it (report-only box) ---------------------
# weectl report run only fires reports; masking weewx.service makes it impossible
# to accidentally start collection/uploads (which would double-publish vs the Zero).
systemctl stop weewx 2>/dev/null || true
systemctl mask weewx.service >/dev/null 2>&1 || true
echo "    weewx.service masked (report-only; never collects/uploads)"

# --- 4) Litestream (install-if-absent; amd64 static binary) ------------------
if command -v litestream >/dev/null 2>&1; then
  echo "    litestream present: $(litestream version 2>/dev/null)"
else
  case "$(uname -m)" in
    x86_64) LS_ARCH=amd64 ;;
    aarch64) LS_ARCH=arm64 ;;
    *) LS_ARCH=amd64 ;;
  esac
  URL="https://github.com/benbjohnson/litestream/releases/download/v$${LS_VER}/litestream-v$${LS_VER}-linux-$${LS_ARCH}.tar.gz"
  if wget -qO /tmp/litestream.tgz "$URL"; then
    tar xzf /tmp/litestream.tgz -C /usr/local/bin litestream && rm -f /tmp/litestream.tgz
    echo "    installed litestream $(litestream version 2>/dev/null) ($${LS_ARCH})"
  else
    echo "    WARN: litestream download failed — re-run the apply"
  fi
fi
# The Zero SFTP-pushes its replica here (authorise its id_litestream key for root).
install -d -m 0755 "$REPLICA"

# --- 5) Report job: restore the replica + regenerate the site ----------------
cat > /usr/local/sbin/weather-report.sh <<EOF
#!/usr/bin/env bash
# platform-managed (weather-compute): restore the Litestream replica + run reports.
set -uo pipefail
REPLICA="${replica_path}"
DB="${db_path}"
LOG=/var/log/weather-report.log
# Restore the newest replica to a temp, then swap in (litestream -o won't clobber).
rm -f "\$DB.new"
if /usr/local/bin/litestream restore -o "\$DB.new" "file://\$REPLICA" >>\$LOG 2>&1; then
  chown weewx:weewx "\$DB.new" 2>/dev/null || true
  mv -f "\$DB.new" "\$DB"
else
  echo "\$(date -Is) restore skipped (replica not ready?)" >>\$LOG
  rm -f "\$DB.new"
fi
# Regenerate Belchertown + Seasons from whatever DB is present.
/usr/bin/weectl report run --config=/etc/weewx/weewx.conf >>\$LOG 2>&1 || \
  echo "\$(date -Is) weectl report run failed" >>\$LOG
EOF
chmod +x /usr/local/sbin/weather-report.sh

cat > /etc/systemd/system/weather-report.service <<'EOF'
[Unit]
Description=Restore the weewx replica + regenerate the weather site
After=network-online.target
[Service]
Type=oneshot
ExecStart=/usr/local/sbin/weather-report.sh
EOF
cat > /etc/systemd/system/weather-report.timer <<EOF
[Unit]
Description=Regenerate the weather site periodically
[Timer]
OnBootSec=3min
OnUnitActiveSec=${report_interval_min}min
AccuracySec=20s
[Install]
WantedBy=timers.target
EOF

# --- 6) nginx — serve the Belchertown site -----------------------------------
# Belchertown + Seasons both render under the weewx HTML_ROOT (/var/www/html/weewx,
# the StdReport default in the migrated weewx.conf); the Belchertown index lands at
# /var/www/html/weewx/index.html, so nginx's root is that dir (index at /).
install -d -m 0755 /var/www/html/weewx
if ! grep -s "weather-compute managed" /etc/nginx/sites-available/default >/dev/null 2>&1; then
  cat > /etc/nginx/sites-available/default <<'EOF'
# weather-compute managed — serve the Belchertown site at /.
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

# --- 7) Enable the report timer ----------------------------------------------
systemctl daemon-reload
systemctl enable weather-report.timer >/dev/null 2>&1 || true
systemctl restart weather-report.timer || true
echo "    weather-report.timer: $(systemctl is-active weather-report.timer 2>/dev/null) (every ${report_interval_min}m)"

echo "==> weather-compute prepped. CUTOVER (manual/coordinated): migrate /etc/weewx"
echo "    (conf + skins + bin/user) from the Zero IF not already staged, authorise the"
echo "    Zero's id_litestream key for root@$(hostname -I | awk '{print $1}'), then flip"
echo "    weather_cutover=true so the Zero starts replicating here."
