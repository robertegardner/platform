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
apt-get install -y wget gnupg dirmngr nginx rsync sqlite3 python3-paho-mqtt python3-setuptools locales imagemagick >/dev/null 2>&1 \
  || echo "    WARN: base package install failed"

# --- 1a) A REAL locale (the LXC default LANG=C is load-bearing) ---------------
# Belchertown embeds the system locale as a BCP-47 tag for the live tiles' JS.
# With LANG=C it bakes "C" into the page; the browser's Intl/toLocaleString then
# throws "Invalid language tag: C" on every MQTT message — Paho catches it as a
# fatal error and drops the connection, so the live-tile MQTT toggles
# connected<->lost forever. Generate en_US.UTF-8 so it embeds "en-US".
locale-gen en_US.UTF-8 >/dev/null 2>&1 && update-locale LANG=en_US.UTF-8 >/dev/null 2>&1 \
  && echo "    locale: en_US.UTF-8 generated" || echo "    WARN: locale-gen failed"

# --- 1b) Timezone = America/Chicago (Cape Girardeau, Central) -----------------
# weectl report run renders timestamps in the system TZ, and Belchertown bakes the
# resulting UTC offset into the page (tzAdjustedMoment). A UTC LXC makes the site
# show times ~5h in the future + confuses the live-tile freshness logic. Set it to
# the station's zone (DST-aware) so the embedded offset is correct year-round.
ln -sf /usr/share/zoneinfo/America/Chicago /etc/localtime
echo "America/Chicago" > /etc/timezone
echo "    timezone: $(date '+%Z %z')"

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

# --- 2b) py3.12 compat for the migrated Belchertown skin ---------------------
# belchertown.py calls locale.format(), REMOVED in Python 3.12 (this LXC is noble
# = 3.12; the Zero's 3.11 still has it). Without this the Belchertown report crashes
# (AttributeError) and only Seasons renders. locale.format_string() has the same
# signature. Idempotent — only bare `locale.format(` calls are touched, and it's a
# no-op once patched / if the skin isn't migrated yet.
BPY=/etc/weewx/bin/user/belchertown.py
if [ -f "$BPY" ] && grep -q "locale\.format(" "$BPY"; then
  sed -i 's/locale\.format(/locale.format_string(/g' "$BPY"
  echo "    patched belchertown.py locale.format -> locale.format_string (py3.12)"
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
# LANG must be a real locale (not C) or Belchertown bakes "C" into the live-tile
# JS and the browser's MQTT handler crashes on every message (see provisioner 1a).
export LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8
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
# Belchertown's HTML_ROOT is /var/www/html (the migrated weewx.conf), so its index
# lands at /var/www/html/index.html — nginx's root is /var/www/html (Belchertown at
# /; Seasons, at the default HTML_ROOT /var/www/html/weewx, is then at /weewx/).
install -d -m 0755 /var/www/html/weewx
if ! grep -s "weather-compute managed" /etc/nginx/sites-available/default >/dev/null 2>&1; then
  cat > /etc/nginx/sites-available/default <<'EOF'
# weather-compute managed — serve the Belchertown site at /.
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    root /var/www/html;
    index index.html;
    server_name _;
    location / { try_files $uri $uri/ =404; }
}
EOF
  echo "    wrote nginx default site (root /var/www/html)"
fi
systemctl enable nginx >/dev/null 2>&1 || true
systemctl restart nginx || echo "    WARN: nginx restart failed"

# --- 7) Enable the report timer ----------------------------------------------
systemctl daemon-reload
systemctl enable weather-report.timer >/dev/null 2>&1 || true
systemctl restart weather-report.timer || true
echo "    weather-report.timer: $(systemctl is-active weather-report.timer 2>/dev/null) (every ${report_interval_min}m)"

# --- 8) Local webcam snapshots (the Zero's getpix.sh, folded onto the rack) ---
# The Belchertown page embeds local camera snapshots from the 192.168.90.x camera
# VLAN (the rack can route to it). On the Zero these came from a getpix.sh cron;
# here a timer fetches them into the web root. KEEP-IF-ABSENT (camera IPs are
# hand-set) so on-box edits survive a re-apply.
if [ ! -f /usr/local/sbin/weather-webcam.sh ]; then
  cat > /usr/local/sbin/weather-webcam.sh <<'SH'
#!/usr/bin/env bash
# platform-managed (weather-compute): fetch local webcam snapshots for the site.
# Edit the camera URLs / output names here if they change.
set -uo pipefail
D=/var/www/html/images; T=$(mktemp -d); install -d "$D"
get(){ wget -q --no-check-certificate -T 12 -O "$T/s.jpeg" "$1"; }
get https://192.168.90.218/snap.jpeg && convert "$T/s.jpeg" "$D/lastimage.png" || echo "cam 218 (lastimage) failed"
get https://192.168.90.205/snap.jpeg && convert "$T/s.jpeg" "$D/backyard.png"  || echo "cam 205 (backyard) failed"
get https://192.168.90.131/snap.jpeg && cp "$T/s.jpeg" "$D/driveway.jpeg"       || echo "cam 131 (driveway) failed"
rm -rf "$T"
SH
  chmod +x /usr/local/sbin/weather-webcam.sh
  echo "    wrote /usr/local/sbin/weather-webcam.sh"
fi
cat > /etc/systemd/system/weather-webcam.service <<'EOF'
[Unit]
Description=Fetch local webcam snapshots for the weather site
[Service]
Type=oneshot
ExecStart=/usr/local/sbin/weather-webcam.sh
EOF
cat > /etc/systemd/system/weather-webcam.timer <<'EOF'
[Unit]
Description=Fetch webcam snapshots periodically
[Timer]
OnBootSec=2min
OnUnitActiveSec=5min
AccuracySec=20s
[Install]
WantedBy=timers.target
EOF
systemctl daemon-reload
systemctl enable weather-webcam.timer >/dev/null 2>&1 || true
systemctl restart weather-webcam.timer || true
# The migrated Belchertown hook hard-codes http://weather.bobgardner.org/images/...
# for the cams — mixed content (blocked) on the HTTPS site. Make them root-relative.
HOOK=/etc/weewx/skins/Belchertown/index_hook_after_station_info.inc
[ -f "$HOOK" ] && sed -i 's#http://weather\.bobgardner\.org/images/#/images/#g' "$HOOK" \
  && echo "    webcam refs in the Belchertown hook made root-relative"

echo "==> weather-compute prepped. CUTOVER (manual/coordinated): migrate /etc/weewx"
echo "    (conf + skins + bin/user) from the Zero IF not already staged, authorise the"
echo "    Zero's id_litestream key for root@$(hostname -I | awk '{print $1}'), then flip"
echo "    weather_cutover=true so the Zero starts replicating here."
