#!/usr/bin/env bash
# goes-archive provisioner — rack LXC (unprivileged). Pulls GOES image products
# off goes.srvr, keeps a rolling ${retention_days}-day archive, and serves the
# gallery + weather2 headline API (goes.rg2.io).
#
# Re-run safe / write-if-absent. NB: remote-exec runs WITHOUT `set -e`.
set -uo pipefail

ARCHIVE=/var/lib/goes-archive
GOES_HOST="${goes_host}"
GOES_USER="${goes_ssh_user}"
GOES_SRC="${goes_output_dir}"
RETENTION="${retention_days}"

echo "==> goes-archive provisioning on $(hostname) — pull $${GOES_USER}@$${GOES_HOST}:$${GOES_SRC} -> $${ARCHIVE}"

# --- 1) Packages ------------------------------------------------------------
need=""
for b in rsync python3 pip3; do command -v "$b" >/dev/null 2>&1 || need="yes"; done
python3 -c "import PIL" 2>/dev/null || need="yes"
if [ -n "$need" ]; then
  apt-get update -qq
  apt-get install -y rsync python3 python3-pil python3-pip >/dev/null 2>&1 || echo "    WARN: apt install failed"
fi
# cbor2 (reads SatDump's projection_cfg to place the roaming mesoscale sectors).
# Same --break-system-packages pattern the radio-compute module uses for pyorbital
# on noble. Without it the headline simply stays crop-only (graceful degrade).
python3 -c "import cbor2" 2>/dev/null || \
  pip3 install --break-system-packages --quiet cbor2 2>/dev/null || \
  echo "    WARN: cbor2 install failed — mesoscale fallback will be disabled (crop-only)"
install -d -m 0755 "$ARCHIVE"

# --- 2) Dedicated pull key (least-privilege) --------------------------------
# Generate a key that lives ONLY on this LXC and authorise it on goes.srvr — we
# do NOT spread the platform deploy key here. ONE-TIME MANUAL STEP: add the
# printed pubkey to goes.srvr:~${goes_ssh_user}/.ssh/authorized_keys. Until then
# the pull fails (logged) and the gallery serves whatever is already archived.
install -d -m 0700 /root/.ssh
if [ ! -f /root/.ssh/id_goes ]; then
  ssh-keygen -t ed25519 -N "" -C "goes-archive-pull" -f /root/.ssh/id_goes >/dev/null
  echo "    generated /root/.ssh/id_goes"
fi
echo "    ===================================================================="
echo "    ONE-TIME: authorise this pull key on $${GOES_HOST} (as $${GOES_USER}):"
echo "      $(cat /root/.ssh/id_goes.pub)"
echo "    ===================================================================="

# --- 3) rsync-pull service + timer ------------------------------------------
# Pull IMAGES + EMWIN + L2 (skip Admin Messages + our own derived/). CRITICAL:
# NO --delete — goes.srvr prunes itself, so a mirror-delete would wipe the
# long-term archive on every pull. Products ACCUMULATE here; the prune timer
# (step 4) caps growth at the retention window. On success we touch
# .last-pull-ok on the Pi: goes-prune there keys its FAST (synced) retention
# off that stamp, so anything older than the stamp is confirmed archived. No
# stamp reaching the Pi = its prune stays on the long fallback window.
cat > /usr/local/sbin/goes-pull.sh <<EOF
#!/usr/bin/env bash
# platform-managed (goes-archive): incremental, non-destructive pull; on
# success stamp .last-pull-ok on the Pi (its goes-prune fast retention gate).
set -uo pipefail
SSH="ssh -i /root/.ssh/id_goes -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=15"
rsync -az --timeout=120 \
  --exclude='Admin Messages/' --exclude='derived/' --exclude='.last-pull-ok' \
  -e "\$SSH" \
  "${goes_ssh_user}@${goes_host}:${goes_output_dir}/" "$ARCHIVE/" || exit \$?
exec \$SSH "${goes_ssh_user}@${goes_host}" "touch '${goes_output_dir}/.last-pull-ok'"
EOF
chmod +x /usr/local/sbin/goes-pull.sh

cat > /etc/systemd/system/goes-pull.service <<'EOF'
[Unit]
Description=Pull GOES products from goes.srvr
After=network-online.target
Wants=network-online.target
[Service]
Type=oneshot
ExecStart=/usr/local/sbin/goes-pull.sh
EOF

cat > /etc/systemd/system/goes-pull.timer <<EOF
[Unit]
Description=Pull GOES products periodically
[Timer]
OnBootSec=45
OnUnitActiveSec=${pull_interval}
AccuracySec=10s
[Install]
WantedBy=timers.target
EOF

# --- 4) Archive prune service + timer ---------------------------------------
cat > /usr/local/sbin/goes-archive-prune.sh <<EOF
#!/usr/bin/env bash
# platform-managed (goes-archive): drop products older than the retention window.
set -uo pipefail
A="$ARCHIVE"
# -mmin (exact) not -mtime: find's "-mtime +N" truncates to whole days and only
# matches at age >= N+1 days — a whole extra day of ~13 GB the volume can't spare.
[ -d "\$A/IMAGES" ] && find "\$A/IMAGES" -mindepth 3 -maxdepth 3 -type d -mmin +${retention_days * 1440} -exec rm -rf {} + 2>/dev/null
[ -d "\$A/L2" ] && find "\$A/L2" -mindepth 3 -maxdepth 3 -type d -mmin +${retention_days * 1440} -exec rm -rf {} + 2>/dev/null
[ -d "\$A/EMWIN" ] && find "\$A/EMWIN" -type f -mmin +${retention_days * 1440} -delete 2>/dev/null
# Derived crops/thumbs regenerate on demand — age them out too, then drop empties.
[ -d "\$A/derived" ] && find "\$A/derived" -type f -mmin +${retention_days * 1440} -delete 2>/dev/null
[ -d "\$A/derived" ] && find "\$A/derived" -mindepth 1 -type d -empty -delete 2>/dev/null
exit 0
EOF
chmod +x /usr/local/sbin/goes-archive-prune.sh

cat > /etc/systemd/system/goes-archive-prune.service <<'EOF'
[Unit]
Description=Prune the GOES archive to its retention window
[Service]
Type=oneshot
ExecStart=/usr/local/sbin/goes-archive-prune.sh
EOF

cat > /etc/systemd/system/goes-archive-prune.timer <<'EOF'
[Unit]
Description=Prune the GOES archive periodically
[Timer]
OnBootSec=15min
OnUnitActiveSec=6h
AccuracySec=5min
[Install]
WantedBy=timers.target
EOF

# --- 5) Gallery / API service -----------------------------------------------
install -d -m 0755 /opt/goes-archive /etc/goes-archive
if [ -f /opt/goes-archive/goes_gallery.py ]; then
  echo "    /opt/goes-archive/goes_gallery.py present — overwriting (provisioner-managed app)"
fi
# The app is provisioner-managed (hashed trigger re-pushes it), so always install
# the pushed copy.
cp /tmp/goes_gallery.py /opt/goes-archive/goes_gallery.py
chmod 0755 /opt/goes-archive/goes_gallery.py
# US state boundaries for the map overlay (provisioner-managed, always refreshed).
[ -f /tmp/us_states.geojson ] && cp /tmp/us_states.geojson /opt/goes-archive/us_states.geojson
# SatDump L2 colormap LUTs for the gallery's product legends.
install -d -m 0755 /opt/goes-archive/luts
[ -d /tmp/luts ] && cp /tmp/luts/*.png /opt/goes-archive/luts/ 2>/dev/null

# Tunables are write-if-absent so on-box calibration (crop box, locality window)
# survives a re-apply.
if [ ! -f /etc/goes-archive/goes.env ]; then
  cat > /etc/goes-archive/goes.env <<EOF
# goes-archive gallery/API config. Edit + 'systemctl restart goes-gallery' to apply.
GOES_PORT=${gallery_port}
GOES_ARCHIVE_DIR=$ARCHIVE
GOES_SAT=GOES-19
GOES_PUBLIC_BASE=${public_base}
# 24/7 headline: Clean Longwave IR carries cloud structure day AND night.
GOES_PREFERRED_COMPOSITE=abi_rgb_Clean_Longwave_IR_Window_Band
# Cape-Girardeau crop of the 5424x5424 full disk (left,top,right,bottom px).
# Tightened regional view (~lat 34.3-40.3, lon -94.3..-84.7) centred on Cape.
GOES_CROP_BOX=1878,758,2321,1000
GOES_HOME_LAT=37.30
GOES_HOME_LON=-89.52
# How close (scan-angle radians dx,dy) a mesoscale centre must be to home to win
# the headline, and how fresh it must be (seconds).
GOES_LOCAL_SCAN_WINDOW=0.020,0.020
GOES_MESO_MAX_AGE_SEC=1800
EOF
  echo "    wrote /etc/goes-archive/goes.env"
else
  echo "    /etc/goes-archive/goes.env present — keeping on-box tuning"
fi

cat > /etc/systemd/system/goes-gallery.service <<'EOF'
[Unit]
Description=GOES archive gallery + weather2 headline API
After=network-online.target
Wants=network-online.target
[Service]
Type=simple
EnvironmentFile=/etc/goes-archive/goes.env
ExecStart=/usr/bin/python3 /opt/goes-archive/goes_gallery.py
Restart=always
RestartSec=5
[Install]
WantedBy=multi-user.target
EOF

# --- 6) Enable + (re)start --------------------------------------------------
systemctl daemon-reload
for u in goes-pull.timer goes-archive-prune.timer goes-gallery.service; do
  systemctl enable "$u" >/dev/null 2>&1 || true
done
systemctl restart goes-gallery.service || echo "    WARN: goes-gallery did not start"
systemctl restart goes-archive-prune.timer || true
# Kick a first pull now (will fail until the pubkey is authorised on goes.srvr).
systemctl restart goes-pull.timer || true
systemctl start goes-pull.service 2>/dev/null || true

echo "    goes-gallery: $(systemctl is-active goes-gallery.service 2>/dev/null) | pull timer: $(systemctl is-active goes-pull.timer 2>/dev/null)"
echo "==> goes-archive done. Browse: http://$(hostname -I | awk '{print $1}'):${gallery_port}/"
