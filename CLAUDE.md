# platform

The acquisition + distribution tier of the SDR homelab. The Pi acquires raw
samples and serves them on the network; the rack does all DSP and serves all
streams. Authoritative design lives in `docs/` — read
`docs/PLATFORM_V2_ARCHITECTURE.md` and `docs/deployment_notes.md` before changing
anything (`docs/session_notes.md` is the quick "where were we" log). Compute
lives in the sibling repos `radio` (v2) and `scanner` (v2); this repo owns the
device registry, the source/mount contracts, and the Terraform that stands the
whole thing up.

## Current state (2026-06-14: V2 RADIO LIVE — wbfm_stream.py over remote dx-R2/TCP)

- **Attic link (2026-06-13): RESOLVED at gigabit (user). New port + cable on
  the Attic Camera Flex switch → eth0 1000FDX, autoneg ON, stable (0 new flaps
  over a ~6 h window incl. warm afternoon). The 100FDX force is gone. The user
  also moved the switch's uplink to a 2.5G port (10GE-capable, links 2.5G; 10G
  planned w/ fiber), lifting the shared-uplink ceiling 1G→2.5G.**
- **V2 RADIO CUT OVER 2026-06-14 — the 2026-06-13 root cause was WRONG.** The
  garble was NOT UDP packet loss: with the IQ forced onto **TCP** (provably — ss
  showed ESTAB/zero-UDP) FM was STILL garbled with dead RDS. Re-diagnosis (see
  session_notes 2026-06-14): the same TCP IQ, captured backpressure-free and
  demodded offline (`tools/demod-iq.py`), gave **336 RDS groups** — perfect. The
  bug is **`rx_fm` itself**: it mishandles SoapyRemote's small MTU-sized partial
  reads (~1006 samples/datagram), breaking FM demod continuity → clicks + dead
  RDS. (Same reason `am_stream.py` already replaced rx_fm for AM.) FIX =
  **`wbfm_stream.py`** (radio repo `files/opt/sdr-tuner/`): a SoapySDR WBFM+RDS
  client that reads IQ directly (phase-continuous), emits the same 250k MPX, and
  forces `remote:prot=tcp`. Bench-proven (rich RDS PI 0x211E / PS KGMO, clean
  audio, retune cycle) then cut over; user confirmed clean. **Lesson: a "clean
  transport" gate (0 overflow/timeout) is necessary-but-NOT-sufficient and can
  pass on a path the live client still wrecks — A/B the real client vs a
  known-good demod, and use RDS as the cheap pass/fail.**
- **Distribution (.82) gained two services (2026-06-12, both in the
  distribution module):** `fm-duck` — talk-ducking relay `/fm.mp3` →
  `/fm-duck.mp3` for GUI-less streamers (WiiM), server-calibrated classifier,
  validated on-air; `icy-pusher` — now-playing → ICY StreamTitle on both
  mounts, with a "<station> at commercial" marker on the duck mount while
  ducked (state via /run/fm-duck/state). Re-provisions no longer restart
  icecast2 unless its config is freshly written. NOTE: fm-duck is a permanent
  /fm.mp3 listener — wxsat's skip-when-listening (radio repo) now queries the
  RACK and discounts it.
- **RADIO = V2 (cut over 2026-06-14):** FM DSP runs **on .84** via
  `wbfm_stream.py` (NOT rx_fm) against the remote dx-R2 over TCP, 100.7 KGMO →
  .82 Icecast. .84 `sdr-fm@active`(enabled)+`sdr-tuner`+`sdr-captions`+
  `fm-watch.timer` all active+enabled. Pi `sdr-fm@active` **masked** (unmask only
  for rollback), `sdr-source@dx-r2` **enabled+active** (:55001), Pi
  `pi-fm-watch.timer` + `sdr-captions` **disabled**. `radio.rg2.io` →
  **192.168.6.84:8080**. Clean audio + rich RDS confirmed by the user. Rollback
  path (R): .84 disable the FM units; Pi unmask+start `sdr-fm@active`, disable
  `sdr-source@dx-r2`, re-enable `pi-fm-watch.timer`+`sdr-captions`; NPM
  radio.rg2.io → radio.srvr:8080.
- **P25 on scanner-compute** (LXC **901**, .83): op25 decodes the **Airspy R2**
  (discone) → rack `/ems.mp3`, LIVE. **Cut over from the interim `rtl-2838`
  2026-06-16** when the user moved the discone to the R2 and pulled the Nooelec.
  op25 does NOT read the R2 directly: gr-osmosdr can't sustain its 80 Mbps
  SoapyRemote stream (stalls; won't force prot=tcp; won't trunk from a file). So
  **`rtltcp-bridge.service`** (NEW, on .83) tight-loops the R2 over SoapyRemote
  (prot=tcp, `wbfm_stream.py` pattern) and re-serves it to op25 as **rtl_tcp CU8**
  (~40 Mbps); op25 runs `--args rtl_tcp=127.0.0.1:1234` (a tunable source, so
  trunk-following works). Gain is server-side in the bridge
  (`IQ_GAINS=LNA:15,MIX:15,VGA:15`, `/etc/scanner-compute/rtltcp-bridge.env`).
  op25-ems `Requires=rtltcp-bridge` (drop-in). Interim-dark:
  `/ems-{fire,police,interop}`, `/monitor.mp3`, EMS transcripts. Scanner
  rollback path (if ever needed): SCHEDULER_EMS_DEFAULT=true + disable
  sdr-source@rtl-2838 + stop op25-ems/ems-stream.
- **Distribution:** `icecast.rg2.io` → rack (.82) via NPM; both mounts
  rack-served (`/fm.mp3` published FROM the Pi, `/ems.mp3` from .83). The
  Pi's icecast2 is RETIRED (2026-06-14: stopped + disabled — SysV service; was
  idle, 0 inbound clients; retiring it left fm/ems/public audio unaffected). Its
  two relay blocks went with it.
  Pi wlan0 is OFF (ARP flux — never re-enable on this wired node).
  RDS on 99.3 is weak/sparse (station-side, not a defect).
- **Distribution:** rack Icecast on LXC **900** (.82) sources BOTH mounts.
  `icecast.rg2.io` proxies to the **Pi's** Icecast, which carries on-demand
  relays for `/fm.mp3` + `/ems.mp3` (marked `platform-cutover` in
  icecast.xml). NPM repoint to .82 is LAST — it retires the relays and the
  Pi's icecast2. (An early NPM repoint before the fm cutover 404'd the public
  radio — don't repoint until every mount is rack-sourced.)
- **Hardware (2026-06-16/17):** Airspy R2 **DONE** (scanner cut over) + Airspy HF+
  **serving NOAA Weather Radio** — `wx-stream.service` on radio-compute NBFM-demods
  the local NWR tx (**162.550**, ~60 dB on the HF+ whip) → continuous `/wx.mp3`
  (`sdr-source@hf-plus` :55002; SoapyAirspyHF built by the pi provisioner). The
  HF+'s eventual AM-broadcast role (dx-R2 long-wire today) is deferred. **ATC
  airband** is on-demand on the R2 (preempts NOAA, the default; see the ems.rg2.io NPM entry).
  **Still waiting:** RTL v4 (Meteor/NOAA path is DARK — dipole + Sawbird were
  pulled to the attic; wxsat-scheduler paused), and the HF+ YouLoop. Before any
  >5 Msps stream into an LXC: raise `net.core.{r,w}mem_max` on **thebeast** (host
  kernel — read-only inside unprivileged LXCs).
- codeserver now has `rsync` — prefer it over tar-over-ssh for thebeast syncs.

## Hosts & roles

- **codeserver.srvr** — Claude Code lives HERE (edit, git, validate). Has SSH to
  the Pi, thebeast, and the LXCs. This is the cockpit.
- **thebeast (192.168.6.163)** — Proxmox host. `terraform` runs here as the
  non-root `deploy` user; `terraform.tfvars` exists here only. Drive it over SSH
  from codeserver — **never run Claude Code interactively on thebeast.**
  remote-exec provisioners SSH out from here into each target.
- **radio (Pi, attic, Server VLAN)** — bare-metal acquisition node, user
  `rgardner`. The live radio host. Treat as production.
- **LXCs (Server VLAN):** `radio-compute`, `scanner-compute`, `distribution`.

Name-resolution quirks (codeserver): use **`radio.srvr` = 192.168.6.18** (bare
`radio`/`pi-attic` don't resolve); **thebeast only by IP** (192.168.6.163).
**`wol.srvr` (192.168.6.24) is a DIFFERENT, unrelated Pi 4** — an ARP/OUI sweep
finds it first; never provision it. NPMplus = 192.168.6.49 (manual LXC, not
Terraform-managed). Ship the tree to thebeast with
`rsync -az terraform tools docs deploy@192.168.6.163:/home/deploy/platform/`.
LXC SSH goes through thebeast (`ssh deploy@163 'ssh -i ~/.ssh/id_rsa_homelab
root@<lxc>'`) — codeserver only holds `id_ed25519`, which the LXCs don't
authorize.

All hosts are on the **Server VLAN → `vlan_id = 0`** (native untagged). The Pi
and LXCs are co-VLAN, so there's no routing between acquisition and compute.

## Repo layout

- `terraform/` — root (`main.tf` wires the modules) + `modules/{pi-acquisition,
  radio-compute,scanner-compute,distribution}`
- `terraform/modules/*/provision-*.sh.tpl` — bash provisioning rendered by
  `templatefile()`, run via `remote-exec` over SSH from thebeast
- `docs/` — `PLATFORM_V2_ARCHITECTURE.md`, `deployment_notes.md`, `session_notes.md`
- `terraform/registry/` — `devices.json` (device→antenna→filter→domain→endpoint;
  the provisioner iterates `present: true` only) and `mounts.json` (audio
  namespace + domain ownership)
- `tools/capture-iq.py` — remote-IQ capture/measure helper (the transport-proof
  harness)
- container resource + Proxmox provider: copy the pattern from homelab-monitor's
  `module.monitoring` — do not re-derive the provider/token wiring

## Deploying

- `terraform` runs on thebeast as `deploy` (reuse the homelab deploy key). Its
  key must be authorized on the Pi (`rgardner`, passwordless sudo for installs)
  and in each LXC.
- **Key pairing:** `ssh_private_key_path` must pair with `ssh_public_key`
  (`~/.ssh/id_rsa_homelab`) — LXCs only authorize the injected key; the Pi
  happens to accept `id_ed25519` too, the containers do not.
- The deploy API token **lacks `Pool.Allocate`** — no Proxmox pool resources;
  platform LXCs carry the `platform` tag instead.
- Any module using bpg resources needs its own `required_providers` block
  (non-hashicorp provider source isn't inherited by name).
- Validate with `terraform validate`. **Never `terraform fmt -recursive`** — it
  reformats `.tfvars` and leaks the Proxmox token (homelab-monitor gotcha).
- Re-provision one target:
  `terraform taint 'module.scanner_compute.null_resource.provision' && terraform apply`.
- **Two cadences.** Infra / deps / units / container specs → `taint` + `apply`.
  Fast app-code iteration → SSH into the LXC, `git pull` + the repo's own
  `deploy.sh` (rsync + restart). Don't `terraform apply` per code change.

## Hard rules

- **Never** `pct exec` or root SSH to thebeast. All ops go through the Proxmox
  API token or SSH into the target.
- **The Pi has NO container resource.** It's bare metal — `null_resource` +
  `remote-exec` only. Never destroy/recreate it. It's the live radio host.
- **Everything is `vlan_id = 0`** (Server, native untagged). Never `vlan_id = 1`
  (`vmbr0` carries `bridge-vids 2-4094`).
- **Vendor SDR drivers live on the Pi ONLY.** Compute LXCs get SoapySDR core +
  the SoapyRemote *client* — never sdrplay/airspy drivers.
- HCL allows **no semicolons**; block args are newline-separated.
- Never commit `terraform.tfvars` or any secret.
- Compute modules do **NOT** `depends_on` `pi-acquisition` or `distribution` — a
  down source/Icecast is a runtime concern, and hard ordering blocks `-target`
  re-provisions.

## The Pi target (pi-acquisition module)

- `null_resource` + `remote-exec` to `radio` over SSH. No container.
- **Everything install-if-absent.** SoapySDR + SoapySDRPlay3 are already built
  from source on the Pi — never rebuild them. Add SoapyRemote *server*,
  SoapyAirspy, SoapyAirspyHF, SoapyRTLSDR only if missing.
- Brings up one source server per device (`sdr-source@.service`) on the ports in
  the device registry, and the platform agent.
- **The platform agent sets the RTL v4 bias-tee** (powers the Sawbird) Pi-side —
  not the SatDump client. **wxsat captures on the dx-R2 Antenna B**
  (`wxsat_capture.sh` borrows the device, not a dedicated RTL v4 yet). **V2
  device handoff (2026-06-14):** the dx-R2 is held by `sdr-source@dx-r2` (serving
  rack FM), so the capture script now **stops `sdr-source@dx-r2` before `rx_sdr`
  and restarts it after** (the `radio` user has a NOPASSWD sudoers grant for it;
  the masked `sdr-fm@active` stop/start are no-ops). After a pass the .84
  `sdr-fm@active` self-heals onto the fresh source via `Restart=always` +
  `fm-watch.timer` (~1–2 min FM gap). Validated by a test capture 2026-06-14.
  **Bias-T:** the `rx_sdr` line passes **no bias-T**, so the Sawbird+ NOAA LNA on
  Antenna B needs external power (the user powers it; or add
  `-d "driver=sdrplay,biasT_ctrl=true"`). Symptom of an unpowered LNA: full
  baseband captures but SatDump decodes 0 CADU (SNR 0 dB, NOSYNC).
- **AM (dx-R2 Antenna C) diagnostic:** `am_stream.py` runs a 5 s noise-floor /
  station-SNR scan on every start → `/run/sdr-streams/rfi_status.json` (+ the
  `sdr-fm@active` journal). `station_snr_db` near/below 0 with only off-grid
  birdies above the floor = no antenna signal (feed/connector fault), NOT a
  receiver bug — HDR/DAB-notch are on and broadcast `rfnotch` is correctly OFF.
- The **device registry** (`docs/` / config) is the source of truth for
  device→antenna→filter→band→domain→endpoint. It replaces the dead RF switch.

## Editing `*.sh.tpl` (templatefile)

- `${var}` — substituted from the module's `templatefile(...)` map.
- `$${VAR}` — escaped → literal `${VAR}` for the runtime shell. Use for every
  brace-syntax shell variable.
- `%{ if cond }` / `%{ for x in y }` … `%{ endif }` / `%{ endfor }` — directives.
- Heredocs `<< 'EOF'` (quoted) so the shell doesn't expand `$`; `templatefile()`
  still substitutes `${var}` inside.

## Known gotchas (these bite when editing provisioning)

- **op25 (boatbod), SatDump, and csdr are source builds** — guard each with
  build-if-absent or a re-apply rebuilds them (minutes each). Mirror
  homelab-monitor's "install the binary only if absent."
- **gr-osmosdr must carry the `soapy` plugin** in `scanner-compute` — it's the
  only path to the remote Airspy R2. There is **no rtl_tcp fallback** (the R2
  isn't RTL).
- After rewriting service configs use **`systemctl enable` + `systemctl restart`**
  — **never `enable --now`** (won't restart a running unit; leaves new config
  unloaded).
- **Provisioners must be re-run safe.** Write configs only if absent (don't
  clobber UI/manual state); `icecast.xml` is guarded by a `platform-managed`
  marker comment (the package ships a default file, so existence alone can't
  gate it).
- **One client per device source.** The scanner scheduler holds one persistent
  client to the R2 and retunes in place — it does not open/close repeatedly.
- **Restart a source FRESH before connecting a live client to it.** A
  `sdr-source@*` instance that's just been hammered by `capture-iq` / IQ
  testing (repeated open/close + rate changes) can be left in a degraded
  state that serves subtly-bad IQ — clean amplitude (mean|IQ|≈0.2, 0% clip)
  but audible demod distortion downstream. Bit the 2026-06-13 FM cutover
  (live rx_fm was connected to the post-IQ-gate source). Cure = the ordered
  bounce. Lesson: `systemctl restart sdr-source@<dev>` after any test window,
  before the live client attaches.
- **Wire format:** CS16 for dx-R2/Airspys, CU8 for the RTL v4; set client-side at
  connect (in the registry). Hold dx-R2 **≤8 Msps** on a single USB hub.
- **Unprivileged LXCs** — no USB passthrough, no device nodes (samples arrive
  over the network). Don't request privileged containers.
- **Retired, do not reintroduce:** the wxsat skip-when-listening gate (Meteor is
  on its own RTL v4 — no contention), the scanner's satellite-preemption job
  (Meteor is radio-domain now), and any RF/GPIO antenna switch.
- **Icecast is rack-side** (`distribution`, 192.168.6.82) but **`icecast.rg2.io`
  still proxies to the Pi** until the per-domain cutover (runbook in
  `deployment_notes.md`). End-state: audio never traverses the Pi link — only
  outbound samples do. The rack Icecast reuses the Pi's source password so
  cutovers change only the host.
- **SoapyRemote needs ~100 MB socket buffers** or 8 Msps streams stall after
  ~6 s — its own sysctl drop never applies post-boot. `provision-pi.sh.tpl`
  persists+applies it; don't remove that block.
- **Remote clients must pass `remote:driver=...`** (e.g. `remote:driver=sdrplay`
  from the registry `soapy_args`) — bare `driver=remote` makes the server open
  its first enumerable device (the busy RTL on the Pi).
- **Default gain saturates the dx-R2 ADC** at 8 Msps (`mean|IQ|≈0.98`) — compute
  clients set sane gain at connect (source contract #4).
- **`sdr-source@{dx-r2,airspy-r2,hf-plus}` are enabled at boot** (post-cutover:
  the rack compute LXCs are their only clients). `sdr-source@rtl-2838` is
  **disabled+stopped** (Nooelec removed 2026-06-16). The old rule — sources
  disabled because the Pi radio claimed the dx-R2 — is retired along with
  `sdr-fm@active` (now masked; unmask only for rollback). Devices remain
  single-client: never point a second consumer at a served device.
- **`remote-exec` inline runs WITHOUT `set -e`** — always chain
  `script && rm -f script` in one line or failures are masked as success.
- **`grep -q` after a pipe + `pipefail` = SIGPIPE race** (fails on genuine
  matches). Use `grep ... >/dev/null` in provisioning checks.
- **op25:** gain element names are device-specific and wrong names are silently
  ignored → deaf receiver. The retired RTL2838's R820T was `TUNER`; the **Airspy
  R2 is `LNA`/`MIX`/`VGA` (0–15 each)** — `run-op25.sh` is keep-if-absent so its
  `GAINS` is hand-edited on .83 at each device cutover (it does NOT auto-rewrite
  from the registry). audio to Icecast goes via liquidsoap + audio.py (`mksafe` —
  op25 emits UDP PCM only during calls; bare ffmpeg stalls and drops the
  mount); needs `python3-setuptools` on noble.

## Bring-up order (state at end of 2026-06-10)

1. ✅ `pi-acquisition` — dx-R2 proven (8 Msps CS16, Gate 0B GO). Remaining
   devices join by flipping `present: true` in the registry + re-apply.
2. ✅ `distribution` — rack Icecast live; **NPM `icecast.rg2.io` → .82 (done,
   user)**. Both mounts rack-served.
3. ✅ `scanner-compute` — op25 LIVE on the interim rtl-2838; `/ems.mp3`
   rack-sourced. Remaining: scanner v2 app work on Airspy R2 arrival.
4. ✅ `radio-compute` — **V2 LIVE (cut over 2026-06-14).** FM DSP on .84 via
   `wbfm_stream.py` over the remote dx-R2/TCP; radio.rg2.io → .84:8080. The
   2026-06-13 attempt rolled back on a MISDIAGNOSIS (blamed UDP; the real bug was
   rx_fm mangling SoapyRemote partial reads — fixed by the Python WBFM client).
   Remaining: stereo mux + HD/AM rack-side (radio repo v2); optional 256k bitrate
   bump.

## NPM proxy map (user-managed; TARGET state for the Android app — see
## deployment_notes "Android app integration")

- `home.rg2.io` → **192.168.6.88:8080** (the unified platform landing page on the
  NEW **dashboard** LXC — vmid 906, `modules/dashboard`). A stdlib-Python
  `http.server` (`dashboard.py`) rendering one Material-Design-3 (dark) tile per
  domain (Radio/Scanner/Satellite/Weather/ADS-B/Distribution): live status + rich
  preview + a dive-in link. **WHY it aggregates server-side:** the page is HTTPS but
  every backend status API is plain HTTP on the Server VLAN, so a browser can't
  `fetch()` them (mixed-content) — a background thread polls them all and the page
  reads ONE same-origin `/api/dashboard`. The GOES thumbnail is proxied via
  `/api/proxy/goes-latest.png` (the gallery returns an absolute `https://goes.rg2.io`
  URL → normalize to path, fetch via the internal `goes_base`); `/fm.mp3` plays from
  the already-TLS `icecast.rg2.io`. Tile sources: radio `.84/api/stack-state`
  (`streams[]` → FM freq + RDS title), scanner `.83:8081/api/status` + `/api/r2/state`
  (`mode`), GOES `.85:8095/api/goes/latest` (`age_sec`), weather `.84:8090/api/alert`
  (EAS) + HEAD `.87`, ADS-B `.86:8080/data/aircraft.json` (count + msg-rate delta),
  Icecast `.82:8000/status-json.xsl` (mounts + listeners). Backend bases are env-tunable
  (`/etc/dashboard/dashboard.env`, keep-if-absent). LIVE 2026-06-30: NPM host **#62**
  (built fresh, not cloned) + LE cert **#77** (empty-meta POST `/api/nginx/certificates`
  — note LE may transiently 500 "Service busy"; retry — then PUT `certificate_id` +
  `ssl_forced`; do NOT clone, which carries the source's cert).
- `icecast.rg2.io` → 192.168.6.82:8000 (rack Icecast — all public audio)
- `scanner.rg2.io` → 192.168.6.83:8080 (op25 console; legacy page is the
  data-complete one under single-receiver rx.py)
- `radio.rg2.io` → **192.168.6.84:8080** (V2 tuner API+UI on radio-compute — the
  Android app's radio backend; repointed here at the 2026-06-14 V2 cutover.
  **Do NOT clean up the Pi's sdr-tuner — it is the wxsat BACKEND.** wxsat is
  Pi-side (the scheduler needs the SDR), so the .84 tuner proxies every
  `/api/wxsat/*` call to the Pi via `WXSAT_UPSTREAM=http://radio.srvr:8080`
  (radio repo 2026-06-14). Keep the Pi sdr-tuner running.)
  **`radio.rg2.io/dash` is the unified whole-stack control surface** (2026-06-18,
  radio `unified-gui`): source tabs FM/AM/NOAA/P25/ATC over `/api/stack-state`;
  `/api/scanner/<path>` proxies scanner-api (.83) → one origin. NOAA/P25/ATC switch
  the single-tuner discone via the **R2-mode coordinator** (`r2-mode.sh` on .83 —
  stop-all → Pi source bounce → start; NOAA is the 24/7 default, P25/ATC preempt).
  `stack-state` reads `r2_role` from the coordinator (`.83 /api/r2/state`), NOT the
  mksafe-padded mounts (`/ems.mp3` + `/scanner-atc.mp3` stay published when idle).
  Extras: **live A/B antenna compare** (HF+ `/am-a.mp3` vs dx-R2/B `/am-b.mp3`,
  instant toggle; `am-compare-a/b.service`); **editable ATC presets**
  (`/var/lib/sdr-streams/atc_presets.json`); **ATC recording/scheduling** —
  `/api/atc-rec/*` + the `atc-rec` 1-min timer tunes ATC for a window, records
  `/scanner-atc.mp3` to `/var/lib/sdr-streams/atc-rec/`, returns to NOAA, prunes
  past N days (one recording at a time; preempts P25/NOAA). 🛠 debug window =
  live `/api/debug-log`. Headless `/dash` screenshots: chromium + puppeteer-core
  on codeserver.)
- `ems.rg2.io` → **192.168.6.83:8081** (scanner-api bridge — the Android
  app's scanner backend; deployed from the scanner repo). Also serves a human
  **EMS captions UI at `/`** (live caption + transcript log from
  scanner-transcribe, via `/api/transcribe` + `/api/transcript`); JSON service
  descriptor moved to `/api`. The page `/` is a **mode-centric scanner UI**
  (2026-06-30 redesign, scanner repo `v2/scanner_api.py` `CAPTIONS_HTML`): a
  `NOAA · default / P25 / ATC` segmented switcher reading `/api/r2/state` (active =
  green dot), with a per-mode panel — **NOAA** `/wx.mp3` player; **P25** live
  talkgroup (`/api/status`) + `/ems.mp3` player + captions + the **op25 console
  embedded in-page** (iframe of scanner.rg2.io, shown ONLY when `mode==p25` so it
  never 502s) + a fullscreen popout; **ATC** the amber-LCD airband tuner
  (`/api/monitor/{tune,stop}`). One click POSTs `/api/r2/mode {mode}` (P25/NOAA) or
  tunes (ATC) → `r2-mode.sh`, with a "switching ~15s" state. ATC/airband
  **preempts NOAA** (the 24/7 default), NOT P25. The retired per-freq
  `atc-listen@<freq>` / `/api/atc/*` path is GONE (superseded by `monitor.service`
  via the coordinator; the provisioner removes the old units). NEVER point it at
  the Pi's old scheduler — its MOSWIN job USB-resets the dongle.
- `wx.rg2.io` → **192.168.6.84:8090** (`wx-alert.service` on radio-compute — a
  NOAA Weather Radio page: `/wx.mp3` player + a live **SAME/EAS alert banner**.
  Decodes alerts off `/wx.mp3` (`ffmpeg | multimon-ng -a EAS`); on an alert fires
  a webhook (`HA_WEBHOOK_URL` in `wx-alert.env` → Home Assistant, for house
  speakers/push) + logs. **ALSO polls api.weather.gov** (`nws_poll_loop`, every
  `WX_NWS_POLL_SEC`=120s, point `WX_NWS_POINT`) for alerts ACTIVE over the home
  point, filtered to the active county set — this catches LONG-FUSE events that
  carry NO dedicated SAME tone on the NWR (heat/air-quality/some flood-wind; e.g.
  an Extreme Heat Warning has SAME eventCode `NWS`, so the audio decoder never
  hears it). NWS-sourced alerts are tagged `source:nws`, tier from NWS severity,
  and are **DISPLAY-ONLY (no webhook)** — the on-air SAME burst stays the house
  trigger; a still-valid SAME alert of ≥ tier wins ties. This is what flows the
  active alert to the dashboard weather tile (which reads `/api/alert`). NPM host
  created (clone of radio.rg2.io). DNS resolves
  via the `*.rg2.io` wildcard, but **needs a per-domain TLS cert** (cloned host
  serves radio.rg2.io's cert). `POST /api/test` injects a test alert. The HA
  webhook needs a non-default `User-Agent` — Cloudflare 403s `Python-urllib`.
  **Embedded into `weather.bobgardner.org`** (weewx 5 / Belchertown skin on
  `weather2.srvr` = 192.168.6.32, ssh `rgardner`): `tools/wx-embed.html` is the
  drop-in widget (top alert bar + minimal player, consumes `/api/alert` CORS).
  weewx gotcha — include the `.inc` with **`#include raw`** (else Cheetah parses
  the JS `$()` → "cannot find 'i'", report aborts), and weewx caches the compiled
  template by the parent `.tmpl` mtime, so after editing `touch` the `.tmpl` +
  `weectl report run`. Details: [[weather2-weewx-belchertown-wx-widget]] memory.)
- `w.rg2.io`, `p.rg2.io` → **192.168.6.87:80** (the weather2 Belchertown site on the
  **weather-compute** LXC — vmid 905, `modules/weather-compute`. The Pi Zero
  `weather2.srvr` still COLLECTS + uploads (Vantage DMPAFT only works over the local
  BT serial) and replicates its archive DB here via **Litestream**; this box runs
  report-only weewx (`weectl report run` Belchertown+Seasons on a 10-min timer, weewxd
  MASKED) + nginx + the local-webcam fetch (`weather-webcam.timer`). LIVE 2026-06-30.
  `weather.bobgardner.org` (Cloudflare tunnel) + NPM host 1 `bobgardner.org` are
  USER-managed repoints → .87. Gotchas: rack needs a real locale (`LANG=C` breaks the
  Belchertown MQTT live tiles) + TZ America/Chicago. Details:
  [[weather2-platform-fold-todo]] memory.)
- `goes.rg2.io` → **192.168.6.85:8095** (`goes-gallery.service` on the NEW
  **goes-archive** LXC — vmid 903, `modules/goes-archive`). Browsable GOES-19 HRIT
  gallery + `/api/goes/{latest,captures,image,space}`. The Pi `goes.srvr`
  (192.168.6.134, dedicated Pi 5) DECODES live (SatDump `goes_hrit`; GOES is
  geostationary so decode stays on the Pi — `modules/pi-goes`, goes.service
  keep-if-absent + 24h SD prune); the LXC rsync-PULLS the products (no --delete),
  keeps 7 days, and serves them. **`/api/goes/latest` is the weather2 headline** =
  Full Disk **cropped to a Cape box** (Clean Longwave IR, 24/7), falling back to a
  Mesoscale sector when one is fresh + local (scan-angle vs Cape from the sector's
  `projection_cfg`; needs cbor2). NPM host id 60 (built via the API — NPMplus
  rejects `access_list_id` on POST/PUT, so don't clone it in; cert 73 issued +
  attached, ssl_forced). `tools/goes-embed.html` is the weather2 widget (same
  `#include raw` + touch-.tmpl gotcha as wx). Details:
  [[goes-archive-integration]] memory.)
- `adsb.rg2.io` → **192.168.6.86:8080** (tar1090 on the NEW **adsb-feeder** LXC —
  vmid 904, `modules/adsb-feeder`). The standalone ADS-B Pi **p24** (192.168.6.141)
  is now DECODE-ONLY (`readsb` 1090 serial 00001090 + `dump978-fa` 978 serial
  00000001; `modules/pi-adsb`; SDR enumeration order REVERSED → select by serial)
  and ships Beast/UAT to the rack. The LXC runs the sdr-enthusiasts **ultrafeeder**
  3-container stack (ultrafeeder + piaware + fr24) as the single hub: aggregates,
  serves the map, fans out to FlightAware/FR24/ADSBx + MLAT, and re-serves Beast
  30005 + SBS 30003 for local consumers. Docker installed via **apt** (the LXC
  template has no curl). Secrets + receiver location in keep-if-absent
  `/etc/adsb-feeder/feeders.env` (NEVER committed; needs a global `UUID=` or
  ultrafeeder's MLAT stays disabled). darthsideous's old FR24 Docker retired;
  scoreboard.srvr (LED matrix, `flightradar.rg2.io`) still pulls p24:30003.
  Details: [[adsb-p24-platform-fold]] memory.)
- `ems.rg2.io` now serves the **V1-style amber-LCD tuner** at `/` (NFM/AM presets
  NOAA WX/Marine/EMS/KCGI-Tower-125.525/Memphis-Center, squelch, direct tune) →
  `/api/monitor/{tune,stop}` → `monitor.service` (NFM/AM on the R2, **preempts
  NOAA** the 24/7 default, auto-returns after 30 min → `/scanner-atc.mp3`).
  Supersedes the per-freq `atc-listen@` template. (This is the ATC panel of the
  mode-centric UI — see the `ems.rg2.io` entry above.)
- `p25.rg2.io` → radio.srvr:8081 (the V1 scanner UI in READ-ONLY mode:
  /listen plays the live op25 feed with captions + the V1 archive pages.
  `SCANNER_UI_READONLY=true` makes it proxy the .83 bridge — it cannot
  reach the old scheduler. Created via tools/npm-proxy.py; note NPMplus
  cert API quirk: POST /api/nginx/certificates takes NO meta keys, and a
  cloned host serves the SOURCE's cert — issue a per-domain cert and PUT
  certificate_id after cloning.)
