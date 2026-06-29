# ADS-B Platform Fold — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fold the standalone ADS-B Pi (p24) into the platform — p24 becomes a Terraform-managed decode-only node; a new rack LXC runs the sdr-enthusiasts *ultrafeeder* as the single hub that aggregates, maps (adsb.rg2.io), and fans out to FlightAware/FR24/ADSBx + MLAT.

**Architecture:** Decoder-on-Pi / hub-on-rack. p24 runs `readsb` (1090ES, SDR 00001090) + `dump978-fa` (UAT, SDR 00000001) and serves Beast/SBS/UAT on the LAN. A new unprivileged LXC (`adsb-feeder`, vmid 904 / 192.168.6.86, `nesting=true`, no USB) runs `docker-adsb-ultrafeeder`, ingests p24's Beast, fans out to the aggregators, and re-serves Beast (30005) + SBS (30003) for local consumers (scoreboard LED matrix).

**Tech Stack:** Terraform (bpg/proxmox), bash provisioners (`templatefile`), Docker + docker compose (ultrafeeder), readsb, dump978-fa, NPMplus.

## Global Constraints
- **Spec:** `docs/superpowers/specs/2026-06-29-adsb-platform-fold-design.md` (authoritative).
- **p24 = 192.168.6.141, live production feeder** — never destroy/recreate; bare metal `null_resource` + `remote-exec` only; everything install-if-absent; SDRs selected **by serial, never index** (00001090 = 1090ES, 00000001 = 978 UAT).
- **Keep the feed alive throughout** — additive (rack hub) FIRST, strip p24 / retire old LAST. Every phase has a rollback.
- **Secrets never committed** — FA feeder-id, FR24 sharing key, ADSBx UUID live only in an uncommitted env file on the LXC (`/etc/adsb-feeder/feeders.env`), reused from the current feeders so site/stats identity carries over.
- **Terraform:** runs on thebeast as `deploy`; ship with `rsync -az terraform tools docs deploy@192.168.6.163:/home/deploy/platform/` (NEVER `--delete`). `terraform validate` before apply; NEVER `terraform fmt -recursive`. Scoped applies via `-target`.
- **LXC rules:** unprivileged, `vlan_id=0`, `features{nesting=true}`, `pool_id=null` (token lacks Pool.Allocate), own `required_providers`, lifecycle `ignore_changes=[tags, initialization[0].user_account, operating_system[0].template_file_id]`.
- **Provisioner rules:** `remote-exec` inline runs WITHOUT `set -e` → chain `script && rm -f script`; write configs only-if-absent (mark managed); `systemctl enable` + `systemctl restart` (never `enable --now`); `grep ... >/dev/null` (not `grep -q`) after a pipe; `.tpl` uses `${var}` (templatefile) / `$${VAR}` (runtime shell).
- **Reach:** p24 = `rgardner@p24.srvr` (codeserver id_ed25519). LXC = `ssh deploy@192.168.6.163 'ssh -i ~/.ssh/id_rsa_homelab root@192.168.6.86'`. scoreboard = `rgardner@scoreboard.srvr` (192.168.6.62). darthsideous = `rgardner@darthsideous.srvr` (192.168.6.111, Docker host).
- **Branch:** `adsb-platform-fold` (already created; spec committed d813995).

---

## Phase 0 — Recon & credential extraction (read-only)

### Task 0: Extract feeder credentials + receiver location
No code changes — gather the values the ultrafeeder env needs. Record them into the (gitignored / scratchpad) notes for Task 2; they go into `/etc/adsb-feeder/feeders.env` on the LXC, never into git.

- [ ] **Step 1: Extract FlightAware feeder-id + receiver lat/lon/alt from p24**
```bash
ssh rgardner@p24.srvr 'sudo piaware-config -show | grep -iE "feeder-id|receiver-lat|receiver-lon"; \
  grep -hiE "lat|lon|alt" /etc/default/dump978-fa /run/dump1090-mutability/* 2>/dev/null | head; \
  sudo cat /var/cache/piaware/feeder_id 2>/dev/null'
```
Expected: a UUID feeder-id and the antenna lat/lon (decimal). Record `FEEDER_ID`, `LAT`, `LON`. If alt not shown, get it from the piaware/adsbx config (`/etc/default/adsbexchange*` or the ADSBx site page).

- [ ] **Step 2: Extract the ADSB-Exchange UUID + feed name**
```bash
ssh rgardner@p24.srvr 'sudo cat /etc/default/adsbexchange 2>/dev/null | grep -iE "uuid|user|alt|lat|lon"; \
  sudo cat /boot/adsbx-uuid /etc/adsbexchange-uuid 2>/dev/null'
```
Expected: ADSBx UUID + the feed/station name + alt. Record `ADSBX_UUID`, `ADSBX_SITENAME`, `ALT`.

- [ ] **Step 3: Extract the FR24 sharing key from the darthsideous container**
```bash
ssh rgardner@darthsideous.srvr 'docker inspect fr24feed | grep -iE "FR24KEY|SHARING|sharing_key"; \
  docker exec fr24feed cat /etc/fr24feed.ini 2>/dev/null | grep -iE "key|fr24"'
```
Expected: the FR24 sharing key. Record `FR24_KEY`.

- [ ] **Step 4: Confirm SDR serial→band mapping and current gain**
```bash
ssh rgardner@p24.srvr 'rtl_test -t 2>&1 | grep -E "SN:"; \
  grep -hiE "gain|serial|device" /etc/default/dump1090-mutability /etc/default/dump978-fa 2>/dev/null'
```
Expected: `SN: 00000001` (978) + `SN: 00001090` (1090). Record current gain(s) (often "agc"/"max" or a number) for `READSB_GAIN` / dump978 gain.

- [ ] **Step 5: Save the gathered values to the scratchpad (NOT git)**
Write `LAT/LON/ALT/FEEDER_ID/ADSBX_UUID/ADSBX_SITENAME/FR24_KEY/READSB_GAIN` to `/tmp/claude-*/scratchpad/adsb-feeders.env` for use in Task 2. These never enter the repo.

---

## Phase 1 — Rack hub (additive; p24 untouched, feed stays alive)

### Task 1: `adsb-feeder` LXC module skeleton + wiring + registry
**Files:**
- Create: `terraform/modules/adsb-feeder/variables.tf`, `terraform/modules/adsb-feeder/main.tf`
- Modify: `terraform/main.tf`, `terraform/variables.tf`, `terraform/registry/devices.json`

**Interfaces:**
- Produces: `module.adsb_feeder` (LXC 904/.86) + `module.pi_adsb` slice `local.adsb_devices`; registry `adsb` domain devices `adsb-1090`, `adsb-978`.

- [ ] **Step 1: Clone `variables.tf` from goes-archive, adapt**
Copy `terraform/modules/goes-archive/variables.tf` → `adsb-feeder/variables.tf`. Keep the standard container vars (vmid, ip, prefix, gw, vlan_id, node, storage, template, bridge, pool_name, ssh_public_key, ssh_private_key_path). Replace the goes-specific vars with:
```hcl
variable "p24_host" {
  description = "p24 (the ADS-B decoder Pi) IP for Beast/UAT ingest"
  type        = string
  default     = "192.168.6.141"
}
variable "tar1090_port" {
  description = "Host port mapped to ultrafeeder tar1090 (container :80)"
  type        = number
  default     = 8080
}
```

- [ ] **Step 2: Write `main.tf` — clone the distribution/goes-archive container block**
Copy the `proxmox_virtual_environment_container` block from `terraform/modules/goes-archive/main.tf` verbatim, changing: resource name `adsb_feeder`, `hostname = "adsb-feeder"`, `tags = ["adsb","platform"]`, `disk { size = 16 }`, `cpu { cores = 2 }`, `memory { dedicated = 2048; swap = 512 }`. Keep `unprivileged`, `features{nesting=true}`, `vlan_id`, lifecycle ignore_changes, own `required_providers`. The `null_resource.provision` block: push `provision-adsb-feeder.sh.tpl` (+ the compose file in Task 2) and chain-exec it; triggers on `sha256(local.provision_script)` + `filesha256` of the compose file. Outputs: `ip`, `vmid`, `tar1090_url = "http://${var.ip}:${var.tar1090_port}/"`. (Full structure mirrors goes-archive/main.tf — same connection, file, remote-exec stanzas.)

- [ ] **Step 3: Add the registry `adsb` domain devices**
In `terraform/registry/devices.json`, after the `goes` entry, add (mirror the `goes` comment style):
```jsonc
"adsb-1090": {
  "_comment": "1090ES on p24.srvr (RTL2832U serial 00001090). p24 DECODES (readsb) and serves Beast/SBS on the LAN; the rack adsb-feeder LXC (904/.86) ingests + aggregates + feeds FA/FR24/ADSBx + MLAT. domain:adsb keeps it out of the other compute loops. Selected by serial, never index.",
  "present": true, "host": "p24.srvr", "soapy_args": "driver=rtlsdr",
  "serial": "00001090", "antenna": "1090 vertical", "role": "adsb-1090es",
  "domain": "adsb", "transport": "beast", "wire_format": "CS8",
  "freq_hz": 1090000000, "sample_rate_default": 2400000, "usb_controller": "p24"
},
"adsb-978": {
  "_comment": "978 UAT on p24.srvr (RTL2838 serial 00000001) via dump978-fa. raw out :30978. Same p24->rack hub flow as adsb-1090.",
  "present": true, "host": "p24.srvr", "soapy_args": "driver=rtlsdr",
  "serial": "00000001", "antenna": "978 vertical", "role": "adsb-978uat",
  "domain": "adsb", "transport": "raw978", "wire_format": "CS8",
  "freq_hz": 978000000, "sample_rate_default": 2083334, "usb_controller": "p24"
}
```

- [ ] **Step 4: Wire `terraform/main.tf`**
Add to `locals`: `adsb_devices = { for id, d in local.present_devices : id => d if d.domain == "adsb" }`. Add `module "pi_adsb"` (source `./modules/pi-adsb`, `adsb_host=var.adsb_host`, `ssh_user=var.adsb_ssh_user`, `ssh_private_key_path`, `devices=local.adsb_devices`) — the module is written in Phase 3 but wire the block now (it's count-gated, so an empty/early state is fine). Add `module "adsb_feeder"` (source `./modules/adsb-feeder`, `vmid=var.vmid_base+4`, `ip=var.adsb_feeder_ip`, the standard LXC var set, `p24_host=var.adsb_host`). No `depends_on`.
> NOTE: `module.pi_adsb` references `./modules/pi-adsb` which doesn't exist until Phase 3. To keep `terraform validate` green now, create the `pi-adsb` module files in **Task 5** BEFORE the first `validate`/apply that includes the wiring — OR comment out the `module "pi_adsb"` block until Phase 3. Choose: comment it out now, uncomment in Task 5.

- [ ] **Step 5: Add root variables**
In `terraform/variables.tf`: `adsb_host` (default `"192.168.6.141"`), `adsb_ssh_user` (default `"rgardner"`), `adsb_feeder_ip` (default `"192.168.6.86"`).

- [ ] **Step 6: Validate**
```bash
rsync -az terraform tools docs deploy@192.168.6.163:/home/deploy/platform/
ssh deploy@192.168.6.163 'cd /home/deploy/platform/terraform && terraform init -input=false >/dev/null && terraform validate'
```
Expected: `Success! The configuration is valid.`

- [ ] **Step 7: Commit**
```bash
git add terraform/modules/adsb-feeder/{variables.tf,main.tf} terraform/main.tf terraform/variables.tf terraform/registry/devices.json
git commit -m "adsb: adsb-feeder LXC module skeleton + registry adsb domain + wiring"
```

### Task 2: ultrafeeder provisioner (Docker + compose + env)
**Files:**
- Create: `terraform/modules/adsb-feeder/provision-adsb-feeder.sh.tpl`, `terraform/modules/adsb-feeder/docker-compose.yml`

**Interfaces:**
- Consumes: Task 0 credentials (into `/etc/adsb-feeder/feeders.env`); Task 1 container.
- Produces: a running `ultrafeeder` container ingesting p24, feeding aggregators, serving tar1090 on `:8080`, Beast `:30005`, SBS `:30003`.

- [ ] **Step 1: Write `docker-compose.yml` (the ultrafeeder service)**
```yaml
services:
  ultrafeeder:
    image: ghcr.io/sdr-enthusiasts/docker-adsb-ultrafeeder:latest
    container_name: ultrafeeder
    hostname: adsb-feeder
    restart: unless-stopped
    env_file: /etc/adsb-feeder/feeders.env
    ports:
      - 8080:80        # tar1090 map
      - 30005:30005    # Beast out (local consumers)
      - 30003:30003    # SBS/BaseStation out (scoreboard)
    environment:
      - TZ=America/Chicago
      - READSB_NET_ENABLE=true
      - UPDATE_TAR1090=true
    tmpfs:
      - /run:exec,size=256M
      - /var/log
    volumes:
      - /opt/adsb-feeder/globe_history:/var/globe_history
      - /opt/adsb-feeder/collectd:/var/lib/collectd
```

- [ ] **Step 2: Write `provision-adsb-feeder.sh.tpl`** (`set -uo pipefail`). Sections:
  1. Install Docker + compose plugin if absent: `command -v docker >/dev/null || (curl -fsSL https://get.docker.com | sh)`; verify `docker compose version`.
  2. `install -d -m 0755 /opt/adsb-feeder /opt/adsb-feeder/globe_history /opt/adsb-feeder/collectd /etc/adsb-feeder`.
  3. Copy the pushed `docker-compose.yml` → `/opt/adsb-feeder/docker-compose.yml` (provisioner-managed, always overwrite).
  4. **`/etc/adsb-feeder/feeders.env` — KEEP-IF-ABSENT** (holds the secrets + receiver location; written once by the operator/Task 3, never clobbered, never in git). On first provision, if absent, write a template with the env keys + placeholder comments:
```bash
if [ ! -f /etc/adsb-feeder/feeders.env ]; then
  cat > /etc/adsb-feeder/feeders.env <<'EOF'
# adsb-feeder secrets + receiver — managed by hand (NEVER committed).
# Receiver location (p24 antenna) drives MLAT for every aggregator:
READSB_LAT=__LAT__
READSB_LON=__LON__
READSB_ALT=__ALT__m
# Ingest p24's decoded streams (1090 Beast + 978 raw):
ULTRAFEEDER_CONFIG=adsb,${p24_host},30005,beast_in;uat,${p24_host},30978,uat_in
# readsb tuning:
READSB_EXTRA_ARGS=
# --- FlightAware ---
FEEDER_ENABLE_FLIGHTAWARE=true
FLIGHTAWARE_FEEDER_ID=__FEEDER_ID__
# --- FlightRadar24 ---
FEEDER_ENABLE_FR24=true
FR24_SHARING_KEY=__FR24_KEY__
# --- ADSB-Exchange ---
FEEDER_ENABLE_ADSBX=true
ADSBX_UUID=__ADSBX_UUID__
ADSBX_SITENAME=__ADSBX_SITENAME__
EOF
  echo "    wrote feeders.env TEMPLATE — fill in the secrets before the stack will feed"
else
  echo "    /etc/adsb-feeder/feeders.env present — keeping operator secrets"
fi
```
  (`${p24_host}` is templatefile-substituted; the `__X__` placeholders are filled by the operator in Task 3 with the Task 0 values. The compose `ULTRAFEEDER_CONFIG`/feeder envs are read from this file via `env_file`.)
  5. Bring it up: `cd /opt/adsb-feeder && docker compose pull && docker compose up -d`. (On a re-provision this is idempotent — recreates only if the compose/env changed.)

- [ ] **Step 3: Wire the compose file push into `main.tf`**
Add a `provisioner "file"` pushing `docker-compose.yml` to `/tmp/docker-compose.yml` (the script copies it into place), and a `compose_hash = filesha256("${path.module}/docker-compose.yml")` trigger. Pass `p24_host` into the `templatefile(...)` map.

- [ ] **Step 4: Validate**
```bash
rsync -az terraform tools docs deploy@192.168.6.163:/home/deploy/platform/
ssh deploy@192.168.6.163 'cd /home/deploy/platform/terraform && terraform validate'
```
Expected: valid.

- [ ] **Step 5: Commit**
```bash
git add terraform/modules/adsb-feeder/{provision-adsb-feeder.sh.tpl,docker-compose.yml} terraform/modules/adsb-feeder/main.tf
git commit -m "adsb: ultrafeeder provisioner (docker compose + keep-if-absent feeders.env)"
```

### Task 3: Apply the hub, fill secrets, verify it feeds (alongside p24)
- [ ] **Step 1: Apply the LXC (scoped)**
```bash
ssh deploy@192.168.6.163 'cd /home/deploy/platform/terraform && terraform apply -auto-approve -target=module.adsb_feeder'
```
Expected: container 904 created; provisioner installs Docker, writes the feeders.env template, brings up ultrafeeder (feeding will be inactive until secrets filled).

- [ ] **Step 2: Fill the real secrets into feeders.env (from Task 0), restart the stack**
```bash
ssh deploy@192.168.6.163 'ssh -i ~/.ssh/id_rsa_homelab root@192.168.6.86 "sed -i \
  -e s/__LAT__/<LAT>/ -e s/__LON__/<LON>/ -e s/__ALT__/<ALT>/ \
  -e s/__FEEDER_ID__/<FEEDER_ID>/ -e s/__FR24_KEY__/<FR24_KEY>/ \
  -e s/__ADSBX_UUID__/<ADSBX_UUID>/ -e s/__ADSBX_SITENAME__/<SITENAME>/ \
  /etc/adsb-feeder/feeders.env && cd /opt/adsb-feeder && docker compose up -d --force-recreate"'
```
(Use the values recorded in Task 0; `<...>` are placeholders.)

- [ ] **Step 3: Verify ingest + aggregators + map**
```bash
ssh deploy@192.168.6.163 'ssh -i ~/.ssh/id_rsa_homelab root@192.168.6.86 "docker ps; \
  docker exec ultrafeeder netstat -tn 2>/dev/null | grep 192.168.6.141:30005; \
  curl -s localhost:8080/data/aircraft.json | head -c 200; \
  docker logs --tail 30 ultrafeeder 2>&1 | grep -iE \"flightaware|fr24|adsbexchange|mlat|feed\""'
```
Expected: container healthy; ESTAB to p24:30005; aircraft.json shows aircraft; logs show FA/FR24/ADSBx connected + MLAT sync. **Confirm on each aggregator's site that the rack feeder is live** (FA stats page, FR24 status, adsbx.org/sync). This may run a few minutes for MLAT to sync.

- [ ] **Step 4: Commit (state only — no repo change)**
No commit; this is a runtime/secret step. Note completion.

**Rollback for Phase 1:** `docker compose down` on .86 + `terraform destroy -target=module.adsb_feeder` (the LXC is additive — p24 + darthsideous FR24 are untouched and still feeding).

---

## Phase 2 — NPM map domain

### Task 4: Publish `adsb.rg2.io` → tar1090
- [ ] **Step 1: Create the proxy host via the API** (mirror the goes.rg2.io method — NPMplus rejects `access_list_id` on POST/PUT and `enabled` on POST; cert POST takes `{provider,domain_names}` only). Use the inline python pattern from the goes work (`~/.config/npm-proxy.env` creds): POST a proxy host `goes.rg2.io`-style for `adsb.rg2.io` → `192.168.6.86:8080` (cert-less first), then POST a LE cert `{provider:"letsencrypt",domain_names:["adsb.rg2.io"]}`, then PUT `certificate_id` + `ssl_forced=true` (dropping `access_list_id`).
- [ ] **Step 2: Verify HTTPS**
```bash
curl -s -o /dev/null -w "%{http_code}\n" https://adsb.rg2.io/   # expect 200, tar1090 map
```
- [ ] **Step 3: Update the CLAUDE.md NPM map + commit**
Add `- \`adsb.rg2.io\` → 192.168.6.86:8080 (ultrafeeder tar1090 on the adsb-feeder LXC)…` near the other entries.
```bash
git add CLAUDE.md && git commit -m "docs: add adsb.rg2.io to the NPM proxy map"
```

---

## Phase 3 — p24 → decode-only (readsb), strip on-Pi feeders

### Task 5: `pi-adsb` module (p24, bare metal)
**Files:**
- Create: `terraform/modules/pi-adsb/variables.tf`, `terraform/modules/pi-adsb/main.tf`, `terraform/modules/pi-adsb/provision-adsb.sh.tpl`
- Modify: `terraform/main.tf` (uncomment `module "pi_adsb"` from Task 1)

- [ ] **Step 1: Clone `variables.tf` + `main.tf` from pi-wxsat**
Copy `terraform/modules/pi-wxsat/{variables.tf,main.tf}` → `pi-adsb/`. Rename `wxsat_host`→`adsb_host`; `devices` = the adsb slice (two devices, so use the full map, not `one()`); `count = length(var.devices) > 0 ? 1 : 0`; connection host `var.adsb_host`, user `var.ssh_user`; file `/tmp/provision-adsb.sh`; chained `chmod +x ... && sudo ... && rm -f ...`. templatefile map: pass `dev_1090_serial` (00001090), `dev_978_serial` (00000001), `gain` (from registry/keep-if-absent).

- [ ] **Step 2: Write `provision-adsb.sh.tpl`** (`set -uo pipefail`). Sections (install-if-absent, reversible):
  1. **DVB blacklist + usbfs** — keep the existing blocks (clone from pi-wxsat verbatim; both already present on p24, write-if-absent).
  2. **Install readsb if absent** — use the wiedehopf install script (the maintained readsb): `bash -c "$(wget -nv -O - https://github.com/wiedehopf/adsb-scripts/raw/master/readsb-install.sh)"` guarded by `command -v readsb >/dev/null ||`. (Long-ish; guard so re-apply is a no-op.)
  3. **Configure readsb for 1090ES on serial 00001090, net out** — write `/etc/default/readsb` keep-if-absent:
```bash
RECEIVER_OPTIONS="--device-type rtlsdr --device 00001090 --gain ${gain} --ppm 0"
DECODER_OPTIONS="--max-range 360"
NET_OPTIONS="--net --net-heartbeat 60 --net-ro-size 1280 --net-ro-interval 0.05 --net-ro-port 30002 --net-sbs-port 30003 --net-bi-port 30004,30104 --net-bo-port 30005"
JSON_OPTIONS="--json-location-accuracy 2"
```
     Then `systemctl enable readsb && systemctl restart readsb`.
  4. **Keep dump978-fa** (serial 00000001, raw 30978) — leave running; just confirm it's enabled.
  5. **Retire the superseded 1090 decoder + on-Pi feeders/maps** (ordered, logged):
```bash
for u in dump1090-mutability piaware adsbexchange-feed adsbexchange-mlat adsbexchange-stats tar1090-adsbx skyaware978; do
  systemctl is-enabled "$u" >/dev/null 2>&1 && { systemctl stop "$u"; systemctl disable "$u"; echo "    retired $u"; } || true
done
```
     (readsb now owns 30002/30003/30005; the aggregators moved to the rack.)

- [ ] **Step 3: Uncomment `module "pi_adsb"` in `terraform/main.tf`** (added/commented in Task 1 Step 4).

- [ ] **Step 4: Validate**
```bash
rsync -az terraform tools docs deploy@192.168.6.163:/home/deploy/platform/
ssh deploy@192.168.6.163 'cd /home/deploy/platform/terraform && terraform init -input=false >/dev/null && terraform validate'
```
Expected: valid (both modules resolve now).

- [ ] **Step 5: Commit**
```bash
git add terraform/modules/pi-adsb/{variables.tf,main.tf,provision-adsb.sh.tpl} terraform/main.tf
git commit -m "adsb: pi-adsb module — readsb (1090) decode-only on p24, retire on-Pi feeders"
```

### Task 6: Apply pi-adsb, verify decode-only + rack re-ingest (no outage)
- [ ] **Step 1: Apply scoped**
```bash
ssh deploy@192.168.6.163 'cd /home/deploy/platform/terraform && terraform apply -auto-approve -target=module.pi_adsb'
```
- [ ] **Step 2: Verify p24 is serving readsb Beast/SBS; old feeders down**
```bash
ssh rgardner@p24.srvr 'systemctl is-active readsb dump978-fa; \
  systemctl is-enabled piaware adsbexchange-feed tar1090-adsbx skyaware978 dump1090-mutability 2>&1; \
  ss -tlnp | grep -E ":30005|:30003|:30002|:30978"'
```
Expected: readsb + dump978-fa **active**; the others **disabled**; ports 30005/30003/30002/30978 listening.
- [ ] **Step 3: Confirm the rack still ingests + aggregators stay fed**
Re-run Task 3 Step 3 checks: ultrafeeder ESTAB to p24:30005, aircraft.json populated, aggregators still live. **No aircraft-count cliff** on `adsb.rg2.io`.

**Rollback:** `systemctl enable --now dump1090-mutability piaware adsbexchange-feed adsbexchange-mlat tar1090-adsbx skyaware978` on p24 (readsb can coexist/stop); registry `adsb-*` → `present:false` makes the module a no-op.

---

## Phase 4 — Repoint consumers, retire old, document

### Task 7: Repoint scoreboard (LED matrix) to the rack
- [ ] **Step 1: Find scoreboard's ADS-B source config**
```bash
ssh rgardner@scoreboard.srvr 'grep -rniE "192.168.6.141|30003|p24" ~ /etc /opt 2>/dev/null | grep -ivE "Binary" | head'
```
Expected: a config/env pointing at `192.168.6.141:30003`.
- [ ] **Step 2: Repoint it to the rack hub** — change the host from `192.168.6.141` → `192.168.6.86` (port 30003 SBS unchanged) in that config, restart the scoreboard service.
- [ ] **Step 3: Verify** the LED matrix still shows flights (ask the user to eyeball it / check the app's log for an ESTAB to .86:30003).

### Task 8: Retire the darthsideous FR24 container
- [ ] **Step 1: Confirm the rack FR24 feeder is live** (FR24 status / `docker logs ultrafeeder | grep -i fr24` shows connected) BEFORE removing the old one.
- [ ] **Step 2: Stop + remove the darthsideous container**
```bash
ssh rgardner@darthsideous.srvr 'docker stop fr24feed && docker rm fr24feed; \
  ls ~/*fr24* /opt/*fr24* docker-compose*.yml 2>/dev/null'
```
(If it's compose-managed, comment out / remove the `fr24feed` service from its compose file so it doesn't come back on `up`.)
- [ ] **Step 3: Verify** FR24 still shows the feed live (now sourced from the rack) on the FR24 status page.

### Task 9: Documentation + memory + finish
- [ ] **Step 1: Update `CLAUDE.md`** — add an ADS-B bullet to "Current state" + "Hosts & roles" (p24 = decode-only ADS-B node; adsb-feeder LXC 904/.86 = ultrafeeder hub) and the registry `adsb` domain note; confirm the `adsb.rg2.io` NPM entry (Task 4).
- [ ] **Step 2: Add a `docs/session_notes.md` entry** (2026-06-29, newest-first) summarizing the fold + cutover.
- [ ] **Step 3: Write/refresh the memory** `adsb-p24-platform-fold.md` (live state, the feeders.env secret location, the cutover done, rollback) + index it in `MEMORY.md`; cross-link `[[weather2-platform-fold-todo]]`.
- [ ] **Step 4: Commit + open the path to merge**
```bash
git add CLAUDE.md docs/session_notes.md
git commit -m "docs: ADS-B fold — p24 decode-only + adsb-feeder hub live"
```
(Then the user decides merge-to-main, mirroring the GOES flow.)

---

## Verification (end-to-end, from the spec)
- p24: `readsb` + `dump978-fa` active; Beast 30005 + SBS 30003 + raw 30002 + UAT 30978 served; old feeders/maps disabled.
- rack: ultrafeeder healthy; `adsb.rg2.io` tar1090 shows aircraft; ingest ESTAB to p24:30005; Beast/SBS re-served.
- aggregators: FA, FR24, ADSBx all show the **rack** feeding + MLAT in sync (same site identity as before).
- scoreboard: LED matrix still working off `.86:30003`.
- darthsideous FR24 container gone; no duplicate feeds.

## Self-review notes
- Spec coverage: every spec section maps to a task (pi-adsb=T5/6, adsb-feeder=T1/2/3, registry/NPM=T1/T4, consumers=T7, darthsideous=T8, cutover order=phase ordering, rollback=per-phase). ✓
- Secrets: only ever in `/etc/adsb-feeder/feeders.env` (keep-if-absent) — never committed; Task 0 extracts, Task 3 fills. ✓
- Live-feed safety: hub stood up additively (Phase 1) and verified feeding BEFORE p24 strip (Phase 3) and darthsideous removal (Phase 4). ✓
