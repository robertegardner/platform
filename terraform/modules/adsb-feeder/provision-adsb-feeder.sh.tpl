#!/usr/bin/env bash
# adsb-feeder provisioner — rack LXC (unprivileged, nesting=true). Runs the
# sdr-enthusiasts ultrafeeder via Docker as the single ADS-B hub: ingests p24's
# decoded Beast (1090) + UAT (978), aggregates, serves tar1090, and fans out to
# FlightAware/FR24/ADSBx + MLAT. No USB — network ingest only.
#
# Re-run safe. The secrets + receiver location live in a KEEP-IF-ABSENT env file
# (/etc/adsb-feeder/feeders.env) that is never committed. NB: remote-exec runs
# WITHOUT `set -e`.
set -uo pipefail

P24="${p24_host}"
echo "==> adsb-feeder provisioning on $(hostname) — ultrafeeder hub, ingest p24=$${P24}"

# --- 1) Docker (+ compose plugin) -------------------------------------------
if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
  echo "    docker + compose present"
else
  echo "    installing docker (get.docker.com)"
  curl -fsSL https://get.docker.com | sh >/dev/null 2>&1 || echo "    WARN: docker install failed"
  systemctl enable docker >/dev/null 2>&1 || true
  systemctl start docker || true
fi

# --- 2) Layout --------------------------------------------------------------
install -d -m 0755 /opt/adsb-feeder /opt/adsb-feeder/globe_history /opt/adsb-feeder/collectd /etc/adsb-feeder

# --- 3) Compose file (provisioner-managed; always refreshed) -----------------
cp /tmp/docker-compose.yml /opt/adsb-feeder/docker-compose.yml

# --- 4) feeders.env — KEEP-IF-ABSENT (secrets + receiver; NEVER committed) ---
# The receiver location (p24 antenna) drives MLAT for every aggregator. On first
# provision we write a TEMPLATE with __PLACEHOLDER__ tokens; the operator fills
# the real secrets (FA feeder-id, FR24 key, ADSBx UUID) once, and re-applies
# never clobber it.
if [ -f /etc/adsb-feeder/feeders.env ]; then
  echo "    /etc/adsb-feeder/feeders.env present — keeping operator secrets"
else
  cat > /etc/adsb-feeder/feeders.env <<EOF
# adsb-feeder secrets + receiver — managed by hand (NEVER committed to git).
# Fill the __PLACEHOLDER__ values once, then: cd /opt/adsb-feeder && docker compose up -d --force-recreate
#
# Receiver location (p24 antenna) — drives MLAT for every aggregator:
READSB_LAT=__LAT__
READSB_LON=__LON__
READSB_ALT=__ALT__
#
# Ingest p24's decoded streams (1090 Beast + 978 raw):
ULTRAFEEDER_CONFIG=adsb,${p24_host},30005,beast_in;uat_in,${p24_host},30978
READSB_NET_CONNECTOR_DELAY=15
#
# --- FlightAware ---
ULTRAFEEDER_CONFIG_FLIGHTAWARE=true
FLIGHTAWARE_FEEDER_ID=__FEEDER_ID__
#
# --- FlightRadar24 ---
ULTRAFEEDER_CONFIG_FR24=true
FR24_SHARING_KEY=__FR24_KEY__
#
# --- ADSB-Exchange ---
ADSBEXCHANGE_UUID=__ADSBX_UUID__
MLAT_USER=__ADSBX_SITENAME__
EOF
  chmod 0600 /etc/adsb-feeder/feeders.env
  echo "    wrote feeders.env TEMPLATE — FILL THE SECRETS before the stack will feed"
fi

# --- 5) Bring the stack up ---------------------------------------------------
cd /opt/adsb-feeder
docker compose pull >/dev/null 2>&1 || echo "    WARN: docker compose pull failed (offline?)"
docker compose up -d || echo "    WARN: docker compose up failed"

echo "    ultrafeeder: $(docker inspect -f '{{.State.Status}}' ultrafeeder 2>/dev/null || echo absent)"
echo "==> adsb-feeder done. Map: http://$(hostname -I | awk '{print $1}'):${tar1090_port}/ (after secrets are filled + recreated)"
