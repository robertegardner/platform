#!/usr/bin/env bash
# pi-weather provisioner — weather2 (Pi Zero 2 W), the LOCAL Davis collector.
#
# weewx COLLECTION stays on the Zero: the Vantage DMPAFT archive download only
# works over the local Bluetooth serial (it fails `no <ACK>` over a ser2net/TCP
# relay). The Zero keeps collecting + the lightweight uploads (WU/PWSweather/
# Influx/MQTT). Only the heavy REPORT generation + web serving move to the rack,
# fed a faithful copy of the archive DB via **Litestream** (continuous SQLite WAL
# replication) pushed to the weather-compute LXC.
#
#   cutover=false (default): install Litestream IDLE — change nothing live.
#   cutover=true: switch the DB to WAL, disable the on-Zero reports (Belchertown +
#     Seasons), stop the web servers, and start Litestream replication. Collection
#     + uploads are only interrupted for the ~seconds it takes to enable WAL.
#
# weather2 is a LIVE node — install-if-absent, re-run safe. NB: remote-exec runs
# WITHOUT `set -e`.
set -uo pipefail

CONSOLE_MAC="${console_mac}"
RACK_HOST="${rack_host}"
REPLICA_PATH="${replica_path}"
LS_VER="${litestream_version}"
DB="${db_path}"
echo "==> pi-weather on $(hostname) — local Davis collector + Litestream -> $${RACK_HOST}:$${REPLICA_PATH} (cutover=${cutover})"

# --- 1) rfcomm-davis: hardened BT console binder (keep — collection needs it) -
# Binds the Davis console to /dev/rfcomm0 over Bluetooth, Restart=always (replaces
# the old rc.local one-shot that never rebinds on drop). weewx reads it LOCALLY.
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
systemctl enable rfcomm-davis.service >/dev/null 2>&1 || true

# --- 2) Litestream (install-if-absent; arch-matched static binary) -----------
if command -v litestream >/dev/null 2>&1; then
  echo "    litestream present: $(litestream version 2>/dev/null)"
else
  case "$(uname -m)" in
    aarch64) LS_ARCH=arm64 ;;
    armv7l|armv6l) LS_ARCH=armhf ;;
    x86_64) LS_ARCH=amd64 ;;
    *) LS_ARCH=arm64 ;;
  esac
  URL="https://github.com/benbjohnson/litestream/releases/download/v$${LS_VER}/litestream-v$${LS_VER}-linux-$${LS_ARCH}.tar.gz"
  if curl -fsSL --retry 4 --retry-delay 5 --max-time 180 "$URL" -o /tmp/litestream.tgz; then
    tar xzf /tmp/litestream.tgz -C /usr/local/bin litestream && rm -f /tmp/litestream.tgz
    echo "    installed litestream $(litestream version 2>/dev/null) ($${LS_ARCH})"
  else
    echo "    WARN: litestream download failed (flaky link?) — re-run the apply"
  fi
fi

# --- 3) Replication key (Zero -> rack, for the Litestream SFTP push) ----------
# Lives only on this Pi; authorise it on the rack ONCE (printed below). Same
# least-privilege pattern as the goes-archive pull key.
install -d -m 0700 /root/.ssh
if [ ! -f /root/.ssh/id_litestream ]; then
  ssh-keygen -t ed25519 -N "" -C "litestream-weather2" -f /root/.ssh/id_litestream >/dev/null
  echo "    generated /root/.ssh/id_litestream"
fi
echo "    ===================================================================="
echo "    ONE-TIME: authorise this key for root@$${RACK_HOST} (Litestream push):"
echo "      $(cat /root/.ssh/id_litestream.pub)"
echo "    ===================================================================="

# --- 4) litestream.yml (replicate the archive DB to the rack over SFTP) -------
cat > /etc/litestream.yml <<EOF
# platform-managed (pi-weather): replicate the weewx archive DB to weather-compute.
dbs:
  - path: ${db_path}
    replicas:
      - type: sftp
        host: ${rack_host}:22
        user: root
        path: ${replica_path}
        key-path: /root/.ssh/id_litestream
EOF
cat > /etc/systemd/system/litestream-replicate.service <<'EOF'
[Unit]
Description=Litestream — replicate the weewx archive DB to the rack
After=network-online.target weewx.service
Wants=network-online.target
[Service]
ExecStart=/usr/local/bin/litestream replicate -config /etc/litestream.yml
Restart=always
RestartSec=10
[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload

%{ if cutover ~}
# ===================== CUTOVER (cutover=true) =====================
echo "    CUTOVER: WAL + disable on-Zero reports + stop web + start Litestream"
# 1) Enable WAL (required by Litestream). Brief weewx stop so the PRAGMA isn't
#    blocked by weewx's open connection; the Davis logger covers the ~seconds gap.
if [ "$(sqlite3 "$DB" 'PRAGMA journal_mode;' 2>/dev/null)" != "wal" ]; then
  systemctl stop weewx 2>/dev/null || true
  sleep 2
  sqlite3 "$DB" "PRAGMA journal_mode=WAL;" >/dev/null && echo "      journal_mode=WAL set"
  systemctl start weewx 2>/dev/null || true
else
  echo "      journal_mode already WAL"
fi
# 2) Disable the heavy reports on the Zero (Belchertown + Seasons) — collection,
#    WU/PWS/Influx/MQTT all stay. configobj edit preserves comments + secrets.
python3 - <<'PY'
import configobj
p = "/etc/weewx/weewx.conf"
c = configobj.ConfigObj(p, encoding="utf-8")
rep = c.get("StdReport", {})
done = []
for name in ("Belchertown", "SeasonsReport"):
    if name in rep:
        rep[name]["enable"] = "false"; done.append(name)
c.write()
print("      reports disabled on the Zero:", done)
PY
systemctl restart weewx 2>/dev/null || true
# 3) Retire the on-Pi web servers (the rack serves the site now).
for u in nginx apache2 lighttpd; do
  if systemctl is-active "$u" >/dev/null 2>&1 || systemctl is-enabled "$u" >/dev/null 2>&1; then
    systemctl stop "$u" 2>/dev/null || true
    systemctl disable "$u" 2>/dev/null || true
    echo "      retired $u"
  fi
done
# 4) Start replication.
systemctl enable litestream-replicate.service >/dev/null 2>&1 || true
systemctl restart litestream-replicate.service || echo "      WARN: litestream-replicate did not start (key authorised on the rack?)"
echo "    litestream-replicate: $(systemctl is-active litestream-replicate 2>/dev/null)"
%{ else ~}
# ===================== STAGED (cutover=false) =====================
# Litestream + key + units are laid down but IDLE. weewx keeps collecting +
# reporting + serving locally exactly as before. Flip cutover=true to switch.
systemctl stop litestream-replicate.service 2>/dev/null || true
systemctl disable litestream-replicate.service 2>/dev/null || true
echo "    STAGED (idle). Authorise the printed key on the rack, then flip cutover=true."
%{ endif ~}

echo "==> pi-weather done (cutover=${cutover})."
