#!/usr/bin/env bash
# comics-display provisioner — rack LXC (unprivileged). Serves a rotating pool
# of classic comics rendered for the reTerminal E1002 (800x480 Spectra 6).
#
# Re-run safe / write-if-absent. NB: remote-exec runs WITHOUT `set -e`, so the
# caller chains this with `&& rm -f` on one line.
set -uo pipefail

echo "==> comics-display provisioning on $(hostname) — port ${comics_port}"

# --- 1) Packages (python3 + Pillow via apt; no pip/venv on the box) ---------
NEED=""
command -v python3 >/dev/null 2>&1 || NEED="$${NEED} python3"
python3 -c 'import PIL' >/dev/null 2>&1 || NEED="$${NEED} python3-pil"
if [ -n "$${NEED}" ]; then
  echo "    installing:$${NEED}"
  apt-get update -qq
  apt-get install -y $${NEED} >/dev/null 2>&1 || echo "    WARN: apt install failed ($${NEED})"
fi

# --- 2) App (provisioner-managed — hashed trigger re-pushes it) -------------
install -d -m 0755 /opt/comics-display /etc/comics-display
# Data dir holds sources.json (UI-owned) + rendered frames — NEVER clobbered here.
install -d -m 0755 /var/lib/comics-display /var/lib/comics-display/pool
cp /tmp/comics.py /opt/comics-display/comics.py
chmod 0755 /opt/comics-display/comics.py

# --- 3) Config (write-if-absent so on-box tuning survives a re-apply) -------
if [ ! -f /etc/comics-display/comics.env ]; then
  cat > /etc/comics-display/comics.env <<EOF
# comics-display config. Edit + 'systemctl restart comics-display' to apply.
# (Source add/drop/enable is done live in the web UI, not here.)
COMICS_PORT=${comics_port}
COMICS_DATA_DIR=/var/lib/comics-display
COMICS_REFRESH_SEC=${refresh_sec}
COMICS_AUTO_ADVANCE_SEC=${auto_advance_sec}
COMICS_TZ=${timezone}
EOF
  echo "    wrote /etc/comics-display/comics.env"
else
  echo "    /etc/comics-display/comics.env present — keeping on-box tuning"
fi

# --- 4) systemd unit --------------------------------------------------------
cat > /etc/systemd/system/comics-display.service <<'EOF'
[Unit]
Description=Rotating comics server for the reTerminal E1002
After=network-online.target
Wants=network-online.target
[Service]
Type=simple
EnvironmentFile=/etc/comics-display/comics.env
ExecStart=/usr/bin/python3 /opt/comics-display/comics.py
Restart=always
RestartSec=5
[Install]
WantedBy=multi-user.target
EOF

# --- 5) Enable + (re)start (never enable --now — won't reload new config) ----
systemctl daemon-reload
systemctl enable comics-display.service >/dev/null 2>&1 || true
systemctl restart comics-display.service || echo "    WARN: comics-display did not start"

echo "    comics-display: $(systemctl is-active comics-display.service 2>/dev/null)"
echo "==> comics-display done. UI: http://$(hostname -I | awk '{print $$1}'):${comics_port}/  device: /next.png"
