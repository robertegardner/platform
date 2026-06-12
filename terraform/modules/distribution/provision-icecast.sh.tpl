#!/usr/bin/env bash
# Rendered by Terraform, executed via SSH as root inside the distribution LXC.
# Installs Icecast and lays down the platform-managed config. RE-RUN SAFE:
# icecast.xml is written only when it does not carry the platform-managed marker,
# so manual/UI edits made after first provision are never clobbered.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

echo "==> Installing icecast2"
# Mute the package's interactive setup prompt; config comes from this script.
echo "icecast2 icecast2/icecast-setup boolean false" | debconf-set-selections
apt-get update -qq
apt-get install -y -qq icecast2 curl

echo "==> icecast.xml (write only if not platform-managed)"
ICECAST_CONFIG_FRESH=0
if grep "platform-managed" /etc/icecast2/icecast.xml >/dev/null 2>&1; then
  echo "    /etc/icecast2/icecast.xml already platform-managed - keeping it"
else
  ICECAST_CONFIG_FRESH=1
  cat > /etc/icecast2/icecast.xml <<'EOF'
<!-- platform-managed: written by the distribution provisioner. Edits survive
     re-provisioning (the provisioner only writes when this marker is absent). -->
<icecast>
    <location>rack</location>
    <admin>icemaster@${icecast_hostname}</admin>

    <limits>
        <clients>100</clients>
        <sources>10</sources>
        <queue-size>524288</queue-size>
        <client-timeout>30</client-timeout>
        <header-timeout>15</header-timeout>
        <source-timeout>10</source-timeout>
        <burst-on-connect>1</burst-on-connect>
        <burst-size>262144</burst-size>
    </limits>

    <authentication>
        <source-password>${source_password}</source-password>
        <relay-password>${source_password}</relay-password>
        <admin-user>admin</admin-user>
        <admin-password>${admin_password}</admin-password>
    </authentication>

    <hostname>${icecast_hostname}</hostname>

    <listen-socket>
        <port>8000</port>
    </listen-socket>

    <http-headers>
        <header name="Access-Control-Allow-Origin" value="*" />
    </http-headers>

    <fileserve>1</fileserve>

    <paths>
        <basedir>/usr/share/icecast2</basedir>
        <logdir>/var/log/icecast2</logdir>
        <webroot>/usr/share/icecast2/web</webroot>
        <adminroot>/usr/share/icecast2/admin</adminroot>
        <alias source="/" destination="/status.xsl"/>
    </paths>

    <logging>
        <accesslog>access.log</accesslog>
        <errorlog>error.log</errorlog>
        <loglevel>3</loglevel>
        <logsize>10000</logsize>
        <logarchive>1</logarchive>
    </logging>

    <security>
        <chroot>0</chroot>
        <changeowner>
            <user>icecast2</user>
            <group>icecast</group>
        </changeowner>
    </security>
</icecast>
EOF
  chown root:icecast /etc/icecast2/icecast.xml
  chmod 640 /etc/icecast2/icecast.xml
  echo "    wrote /etc/icecast2/icecast.xml"
fi

# Debian/Ubuntu historically gate the daemon behind /etc/default/icecast2.
if [ -f /etc/default/icecast2 ]; then
  sed -i 's/^ENABLE=.*/ENABLE=true/' /etc/default/icecast2
fi

echo "==> enable icecast2; restart ONLY on fresh config (a restart drops every"
echo "    listener AND the Pi's publishing ffmpeg — ~2 min fm.mp3 outage until"
echo "    pi-fm-watch heals it; never disturb a healthy daemon on re-provision)"
systemctl enable icecast2
if [ "$${ICECAST_CONFIG_FRESH}" = "1" ] || ! systemctl is-active icecast2 >/dev/null; then
  systemctl restart icecast2
  sleep 2
fi
systemctl is-active icecast2

echo "==> fm-duck: server-side talk-ducked relay mount (/fm-duck.mp3)"
# Decode->classify->gain->re-encode of the local /fm.mp3 so GUI-less network
# streamers (WiiM) get ducking by URL choice. App + unit + env are
# deterministic from this template, so they are (re)written every provision —
# unlike icecast.xml there is no manual state to preserve.
apt-get install -y -qq ffmpeg python3-numpy
install -d -m 0755 /opt/fm-duck
# fm_duck.py is pushed to /tmp by a Terraform file provisioner (see main.tf).
install -m 0755 /tmp/fm_duck.py /opt/fm-duck/fm_duck.py && rm -f /tmp/fm_duck.py

cat > /etc/fm-duck.env <<'EOF'
SOURCE_URL=http://127.0.0.1:8000/fm.mp3
MOUNT_URL=icecast://source:${source_password}@127.0.0.1:8000/fm-duck.mp3
EOF
chmod 600 /etc/fm-duck.env

cat > /etc/systemd/system/fm-duck.service <<'EOF'
[Unit]
Description=Talk-ducked relay of /fm.mp3 -> /fm-duck.mp3 (for GUI-less streamers)
After=network-online.target icecast2.service
Wants=icecast2.service

[Service]
# Exits whenever the upstream mount drops (Pi restarts the stream on every
# tune); restart until it returns. EnvironmentFile is root-only (source
# password) — systemd reads it before dropping to User=.
EnvironmentFile=/etc/fm-duck.env
ExecStart=/usr/bin/python3 /opt/fm-duck/fm_duck.py
User=icecast2
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable fm-duck
systemctl restart fm-duck

echo "==> icy-pusher: now-playing -> ICY StreamTitle on the audio mounts"
# Network streamers (WiiM) display ICY metadata natively; pushed via the
# Icecast admin metadata endpoint from the backend's /api/now_playing.
install -d -m 0755 /opt/icy-pusher
# icy_pusher.py is pushed to /tmp by a Terraform file provisioner (see main.tf).
install -m 0755 /tmp/icy_pusher.py /opt/icy-pusher/icy_pusher.py && rm -f /tmp/icy_pusher.py

cat > /etc/icy-pusher.env <<'EOF'
NOW_PLAYING_URL=https://radio.rg2.io/api/now_playing
ICECAST_ADMIN=http://127.0.0.1:8000
ADMIN_USER=admin
ADMIN_PASS=${admin_password}
MOUNTS=/fm.mp3 /fm-duck.mp3
EOF
chmod 600 /etc/icy-pusher.env

cat > /etc/systemd/system/icy-pusher.service <<'EOF'
[Unit]
Description=Now-playing -> Icecast ICY StreamTitle metadata (WiiM display)
After=network-online.target icecast2.service
Wants=icecast2.service

[Service]
# EnvironmentFile is root-only (Icecast admin password) — systemd reads it
# before dropping to User=.
EnvironmentFile=/etc/icy-pusher.env
ExecStart=/usr/bin/python3 /opt/icy-pusher/icy_pusher.py
User=icecast2
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable icy-pusher
systemctl restart icy-pusher

echo "==> provisioning complete"
curl -sS -m 5 http://localhost:8000/status-json.xsl >/dev/null && echo "    status endpoint OK"
