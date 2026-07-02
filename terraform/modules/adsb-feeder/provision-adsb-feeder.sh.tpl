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
# Install via apt (the Ubuntu LXC template ships no curl, so get.docker.com is
# out). docker.io + docker-compose-v2 give dockerd + the `docker compose` plugin,
# and run fine in this unprivileged LXC (overlayfs + cgroup v2, nesting on).
if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
  echo "    docker + compose present"
else
  echo "    installing docker.io + docker-compose-v2 (apt)"
  apt-get update -qq
  apt-get install -y docker.io docker-compose-v2 >/dev/null 2>&1 || echo "    WARN: docker install failed"
  systemctl enable docker >/dev/null 2>&1 || true
  systemctl start docker || true
fi

# nftables.service must stay DISABLED on this Docker host (2026-07-02): a
# package-upgrade restart of it runs the stock /etc/nftables.conf whose
# `flush ruleset` wipes Docker's NAT chains — every container silently loses
# egress AND LAN while staying "healthy" (killed FA/ADSBx/MLAT for ~5 h). The
# stock config is an empty accept-all skeleton, so nothing is lost. NEVER
# `systemctl stop`/`disable --now` it while active — its ExecStop ALSO runs
# `nft flush ruleset`. (If it ever bites anyway: `systemctl restart docker`
# rebuilds the rules.)
if [ "$(systemctl is-enabled nftables 2>/dev/null)" = "enabled" ]; then
  systemctl disable nftables >/dev/null 2>&1 || true
  echo "    nftables.service disabled (docker-NAT flush guard)"
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
# Global UUID — REQUIRED for ultrafeeder's mlat-client (it checks a global UUID/
# MLAT_USER at startup and disables MLAT before reading the per-line uuid=).
UUID=__ADSBX_UUID__
#
# ultrafeeder: ingest p24 (1090 Beast + 978 UAT) + feed ADSB-Exchange (native).
ULTRAFEEDER_CONFIG=adsb,${p24_host},30005,beast_in;adsb,${p24_host},30978,uat_in;adsb,feed1.adsbexchange.com,30004,beast_reduce_plus_out,uuid=__ADSBX_UUID__;mlat,feed.adsbexchange.com,31090,uuid=__ADSBX_UUID__
READSB_NET_CONNECTOR_DELAY=15
#
# --- FlightAware (piaware sidecar) ---
FEEDER_ID=__FEEDER_ID__
#
# --- FlightRadar24 (fr24 sidecar) — dual keys: 1090 + UAT direct from p24 ---
FR24KEY=__FR24_KEY__
FR24_SHARING_KEY_UAT=__FR24_KEY_UAT__
UATHOST=${p24_host}
UATPORT=30978
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
