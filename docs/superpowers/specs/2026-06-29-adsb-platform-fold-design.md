# ADS-B platform fold — design

## Context
`p24.srvr` is a standalone outdoor ADS-B feeder Pi running two RTL-SDRs (1090ES +
978 UAT). Today it both **decodes** and **feeds** multiple aggregators directly, and a
third feeder (FlightRadar24) runs as a Docker container on a *different* host
(darthsideous). The feeders are scattered and unmanaged by the platform. Goal: fold p24
into the platform with the same philosophy as the radio/scanner/GOES tiers — **the Pi
manages its SDRs and decodes; the rack becomes the single hub that aggregates and
distributes** to all the external aggregators + a local map, all Terraform-managed.

## End-state decisions (agreed)
- **Full hub on the rack.** p24 decodes only and ships Beast to the rack; a new platform
  LXC runs ALL feeders (FlightAware, FR24, ADSB-Exchange) + MLAT + the map.
- **Hub tech = ultrafeeder in a platform LXC.** `sdr-enthusiasts/docker-adsb-ultrafeeder`
  as Docker inside a new unprivileged LXC (`nesting=true`, no USB — it only ingests Beast
  over the network). Matches the existing sdr-enthusiasts FR24 image already in use.
- **Modernize p24's 1090 decoder to `readsb`** (replacing dump1090-mutability); keep
  `dump978-fa` for UAT.
- **Map domain `adsb.rg2.io`** → the rack tar1090. (`flightradar.rg2.io` is taken — it's
  the scoreboard LED-matrix display, see below.)
- **MLAT carries over** (per-aggregator, from p24's antenna location).

## Current state (probed 2026-06-29)
- **p24** (192.168.6.141, RPi 4, outdoor; live — treat as production, 37+ day uptime):
  - `dump1090-mutability` ← SDR serial **00001090** (1090ES). Outputs Beast 30005, raw
    30002, **SBS 30003**, BaseStation; net-connector to ADSBx (feed1.adsbexchange.com).
  - `dump978-fa` ← SDR serial **00000001** (978 UAT). raw 30978, json 30979.
  - On-Pi feeders: `piaware` (FlightAware), `adsbexchange-feed/mlat/stats`. Local maps:
    `tar1090-adsbx` (8504), `skyaware978` (8978), lighttpd :80.
  - usbfs tuning + DVB blacklist already in place (from the shelved wxsat work).
- **darthsideous** (192.168.6.111): `ghcr.io/sdr-enthusiasts/docker-flightradar24`
  container, pulls p24 Beast (30005); status site :8754. Healthy (~11M msgs).
- **scoreboard.srvr** (192.168.6.62): a Pi running an **LED-matrix flight display**,
  served at `flightradar.rg2.io` (→ scoreboard.srvr:5000). Consumes p24's **SBS (30003)**
  feed (two connections). Stays its own project — NOT folded in now.

## Architecture

```
p24 (outdoor Pi)  ── pi-adsb module ──┐         rack LXC "adsb-feeder" (.86) ── adsb-feeder module
  readsb     ← SDR 00001090 (1090ES)  │         Docker: sdr-enthusiasts/docker-adsb-ultrafeeder
  dump978-fa ← SDR 00000001 (978 UAT) ├─Beast──►  ├ readsb (aggregator/decoder-combine)
  net out: Beast 30005, SBS 30003,    │  30005    ├ tar1090 map ───────────────► adsb.rg2.io
           raw 30002, UAT 30978       └─UAT────►  ├ FlightAware feeder ─────────► FA
  (feeders + local maps REMOVED)         30978    ├ FR24 feeder ────────────────► FlightRadar24
                                                  ├ ADSB-Exchange feeder + MLAT ─► ADSBx
                                                  ├ (MLAT per aggregator, p24 loc)
                                                  └ Beast 30005 + SBS 30003 out ─► local consumers
                                                                                   (scoreboard .62)
```

**Data flow:** p24 decodes both bands and serves Beast/SBS/UAT on the LAN (decoder-only).
The rack ultrafeeder is the single consumer of p24 for aggregation, then fans out to FA /
FR24 / ADSBx (each with MLAT from p24's antenna lat/lon/alt) and re-serves Beast (30005) +
SBS (30003) so local consumers (scoreboard, anything else) point at the **rack**, not p24.

## Components

### 1. `terraform/modules/pi-adsb` (p24, bare metal)
Mirror `pi-acquisition`/`pi-wxsat`: `null_resource` + `remote-exec`, no container, count-
gated on the `adsb` domain devices, install-if-absent, **never destroy/recreate** (live
feeder). `provision-adsb.sh.tpl`:
- Install `readsb` (wiedehopf/sdr-enthusiasts package) if absent; configure for 1090ES on
  **SDR serial 00001090** (selected by serial, never index — same hard rule as wxsat).
  Net outputs: Beast 30005, SBS 30003, raw 30002, JSON. Gain configurable (keep-if-absent
  env like run-op25 GAINS so hand-tuning survives).
- Keep `dump978-fa` (serial 00000001) as-is (raw 30978).
- **Decommission the on-Pi feeders/maps:** stop + disable `piaware`,
  `adsbexchange-feed/mlat/stats`, `tar1090-adsbx`, `skyaware978`, and retire
  dump1090-mutability (readsb supersedes it). Done as an ordered, reversible step in the
  cutover, NOT silently.
- Keep the usbfs + DVB-blacklist blocks. Registry: domain `adsb`, two devices
  (`adsb-1090` serial 00001090, `adsb-978` serial 00000001), `host: p24.srvr`.

### 2. `terraform/modules/adsb-feeder` (rack LXC, vmid 904 / 192.168.6.86)
Clone the `goes-archive`/`distribution` bpg container pattern (own `required_providers`,
unprivileged, `vlan_id=0`, `features{nesting=true}`, `pool_id=null`, lifecycle
`ignore_changes`). Sizing: 2 cores / 2 GB / ~16 GB disk (tar1090 history/graphs + Docker
images). Provisioner:
- Install Docker (+ compose plugin) — nesting LXC, no USB/devices needed (Beast over net).
- Deploy `docker-adsb-ultrafeeder` via a compose file + an env file:
  - `ULTRAFEEDER_CONFIG`: ingest p24 1090 (`adsb,192.168.6.141,30005,beast_in`) + 978
    (`uat_in` from `192.168.6.141,30978`); enable tar1090; expose Beast 30005 + SBS 30003.
  - `READSB_LAT/LON/ALT` + receiver accuracy = p24's antenna location (carries MLAT).
  - Feeder blocks: FlightAware, FR24, ADSBx (+ per-aggregator MLAT).
  - **Secrets (FA feeder-id, FR24 sharing key, ADSBx UUID) in an uncommitted env file**
    (`/etc/adsb-feeder/feeders.env`, keep-if-absent) — **reused from the current p24/
    darthsideous feeders** so each site's stats history carries over. Never committed.
- systemd unit (or compose `restart: unless-stopped`) brings the stack up on boot.

### 3. Registry / NPM / main.tf wiring
- `registry/devices.json`: `adsb` domain, the two devices above (`present: true`).
- `main.tf`: `local.adsb_devices`, `module.pi_adsb` (devices), `module.adsb_feeder`
  (vmid_base+4 = 904, ip .86). Compute module does NOT `depends_on` pi-adsb.
- `variables.tf`: `adsb_host` (p24 IP 192.168.6.141), `adsb_feeder_ip` (.86).
- NPM (user-managed): `adsb.rg2.io` → `192.168.6.86:8080` (ultrafeeder tar1090, container
  port 80 mapped to host 8080) + per-domain cert
  (same NPMplus quirk noted for goes: build the host via API, `access_list_id` rejected).
  `flightradar.rg2.io` (scoreboard) unchanged.

### 4. Downstream consumers
After cutover, repoint **scoreboard.srvr** from `p24:30003` → `adsb-feeder(.86):30003`
(SBS). Any other local consumer repoints to the rack hub likewise. The rack becoming the
single distribution point is the "platform distributes it" goal.

## Cutover sequence (keep the feed alive throughout)
1. Stand up the `adsb-feeder` LXC + ultrafeeder **alongside** the existing setup,
   ingesting p24's current Beast (p24 unchanged at this point). Migrate FA/FR24/ADSBx
   credentials into the ultrafeeder env.
2. Confirm each aggregator (FA, FR24, ADSBx) now shows the **rack** as the live feeder
   (rx_connected, MLAT sync), and tar1090 on `adsb.rg2.io` shows aircraft.
3. Stop the **darthsideous FR24** container and the **p24 on-Pi feeders/maps**.
4. Apply the `pi-adsb` module: install readsb, retire dump1090-mutability, confirm Beast/
   SBS still served; the rack re-ingests cleanly.
5. Repoint scoreboard (.62) to the rack's SBS (30003); verify the LED matrix still works.

## Rollback
Re-enable p24's `piaware`/`adsbexchange-*` + dump1090-mutability and the darthsideous FR24
container; point scoreboard back at p24:30003. (readsb and the LXC can stay; rollback only
needs the old feeders re-enabled. p24 is `count`-gated + install-if-absent — flipping the
registry to `present:false` is a no-op on the Pi.)

## Verification
- p24: `readsb` active on serial 00001090, Beast 30005 + SBS 30003 served; dump978-fa
  active; old feeders/maps stopped+disabled. `ss -tlnp` shows the expected ports.
- rack: `docker ps` ultrafeeder healthy; `curl .86:8080/` tar1090 loads with aircraft;
  ingest connected to p24; Beast 30005 + SBS 30003 exposed.
- aggregators: FA (flightaware.com/adsb/stats), FR24 (fr24feed status :8754-equiv), ADSBx
  (adsbx.org/sync MLAT) all show the rack feeding + MLAT in sync.
- scoreboard: LED matrix still shows flights after repoint to .86:30003.
- `adsb.rg2.io` loads over HTTPS (cert attached); darthsideous FR24 container gone.

## Open items / risks
- **Feeder credential extraction:** FA feeder-id, FR24 sharing key, ADSBx UUID must be
  read off the current p24/darthsideous configs and moved to the rack env (preserves site
  identity/stats). Gather at implementation; never commit.
- **MLAT location accuracy:** ultrafeeder needs p24's exact antenna lat/lon/alt — pull
  from the current piaware/adsbx config.
- **readsb cutover on a live outdoor Pi:** one-time risk; do it after the rack is already
  feeding so there's no outage window. usbfs tuning stays.
- **Docker-in-unprivileged-LXC:** works with `nesting=true` and no device passthrough
  (Beast is network-only). Confirm the platform LXC template supports it (it should —
  same kernel features the other LXCs use).
- **adsb.fi / airplanes.live / Planefinder / RadarBox:** not in scope now; ultrafeeder
  makes them one env block each later if wanted.
