# wxsat Pi-local capture — store-and-forward over the Garage UDB

**Date:** 2026-07-02
**Status:** approved (design), pending implementation plan
**Branch basis:** `wxsat-decode-timeout-leak-fix` (db4b2e1 — killpg/timeout decode
fixes are kept and reused)

## Problem

Meteor LRPT acquisition is fully network-dependent: the rack scheduler on .84
streams IQ live from `wxsat-rtltcp` on goes.srvr (192.168.6.134) for the whole
~15-minute pass. goes.srvr sits **outside on the Garage UDB wireless bridge**;
a link flap at any point in the window kills or truncates the capture. The
2026-07-02 01:37Z M2-3 pass was lost to exactly this ("No route to host" at
connect). GOES on the same Pi survives outages because it is store-and-forward
(decode local, .85 rsync-pulls later). Meteor must work the same way.

## Design (approved 2026-07-02)

Capture becomes Pi-local; the rack becomes a sync + decode consumer. Live
per-pass visibility is kept, served from the Pi.

### Pi side (goes.srvr, `pi-wxsat` module)

- **`wxsat-scheduler.service`** (new, on the Pi): the existing
  `wxsat_scheduler.py` + `wxsat_predict.py`, with rack-isms removed
  (no LXC clock-gate skip, no rack paths). Predicts passes for
  METEOR-M2 3 + METEOR-M2 4 from a **cached TLE file** and launches the capture
  script at AOS. `MIN_ELEV_DEG`, sats, and dry-run stay env-tunable
  (`/etc/wxsat/wxsat.env`, keep-if-absent).
- **Capture script** (`wxsat_capture_pi.sh`, slimmed from
  `wxsat_capture_rack.sh`): records CU8 from **localhost rtl_tcp**
  (`127.0.0.1:1234`) via the existing `wxsat_record_rtltcp.py`, unchanged, into
  `/var/lib/wxsat/captures/<ts>Z/`:
  - `baseband.cu8.part` while recording → renamed `baseband.cu8` at LOS
  - `pass.json` (sat, AOS/LOS, max elev, gain, samplerate — same schema as today)
  - `capture.log`
  - **`capture.done`** marker written last — the completeness contract for sync.
    Failed captures write `capture.failed` (with the rc) instead, so the rack
    can surface them.
  - **No decode on the Pi** — GOES owns the Pi's CPU headroom.
- **rtl_tcp stays the capture source.** `wxsat-rtltcp.service` keeps running as
  today; recording from 127.0.0.1 reuses the recorder verbatim and naturally
  locks out remote clients during a pass (rtl_tcp is single-client). Remote
  diagnostics (rf_sweep etc.) keep working between passes.
- **Dongle recovery ladder** in the capture script, given the 07-01/07-02 wedge
  history: on connect failure or a 0-byte stream → `systemctl restart
  wxsat-rtltcp`, retry once; still dead → `usbreset` the Meteor dongle's
  bus/devnum (resolved by serial 74111838, NEVER the GOES dongle), restart,
  retry once more. All attempts logged to `capture.log`.
- **Live sidecar on the Pi:** `wxsat_live.py` ports as-is (it tails the growing
  `.part` file on disk; nothing about it is rack-specific except paths). It
  writes `wxsat_live.json` into `/run/wxsat/`, launched/killed by the capture
  script exactly as the rack variant is today. Decode-phase telemetry no longer
  applies on the Pi (decode is rack-side); the sidecar covers the recording
  phase (spectrum/waterfall, level, az/el, pass arc) and exits at LOS.
- **`wxsat-http.service`** (new, tiny): stdlib `http.server` on **:8078**,
  document root `/var/lib/wxsat/http/` containing two symlinks —
  `live -> /run/wxsat` and `captures -> /var/lib/wxsat/captures` — so the URL
  layout is `/live/wxsat_live.json` and `/captures/<ts>Z/...`, read-only.
  Gives the rack the live feed and a debugging window into pending captures.
- **Prune:** `wxsat-prune.timer` deletes capture dirs older than **72 h**
  (~450 MB/pass × ~5 passes/day ≈ 7 GB peak — bounded, and a multi-day outage
  still hands over what fits). Same shape as the GOES 24 h SD prune. The rack
  never deletes on the Pi.
- **TLE freshness:** the Pi cannot fetch TLEs itself (`/etc/hosts` blackholes
  celestrak for SatDump fast-fail). The **rack pushes** the TLE file it already
  fetches (scp to `/var/lib/wxsat/tle/`, piggybacked on the sync timer whenever
  the link is up). The Pi predictor uses the cached file and logs a WARNING when
  it is >7 days stale; predictions degrade gracefully (TLE drift over weeks is
  minutes-level, well inside the capture padding).

### Rack side (.84, `radio-compute` module)

- **`wxsat-scheduler.service` is replaced by `wxsat-sync.timer` +
  `wxsat-sync.service`** (~5 min cadence, goes-pull pattern):
  1. Push the current TLE file to the Pi (best-effort).
  2. `rsync` capture dirs that contain `capture.done` or `capture.failed`
     (no `--delete`) into `/var/lib/sdr-streams/wxsat/`.
  3. For each pulled, un-decoded capture: run the existing SatDump decode
     exactly as today — `timeout -k 15 $WXSAT_DECODE_TIMEOUT` wrapper,
     `start_new_session` + killpg backstop from db4b2e1 all kept.
  4. Update `captures.json`, send the existing ntfy notifications
     (`wxsat_notify.py`) for pass recorded / decode result / failed captures.
  5. Mark decode completion with a `decode.done` marker in the capture dir
     (rack copy) so re-runs are idempotent.
- **Gallery / API unchanged:** products land in the existing
  `/var/lib/sdr-streams/wxsat/` layout, so `radio.rg2.io/wxsat`,
  `/api/wxsat/*`, and the home.rg2.io ☄️ tile need no changes.
- **Live visibility kept:** `/api/wxsat/live` on .84 (sdr-tuner) proxies
  `http://goes.srvr:8078/live/wxsat_live.json` with a ~1 s timeout,
  best-effort. Link down ⇒ the endpoint reports `{"available": false}` and the
  UI shows "live view unavailable (link down) — capture continues on the Pi".
  Track/arc data comes through the same JSON as today.

### Failure modes

| Failure | Behavior |
|---|---|
| UDB down at AOS | Pi captures normally; rack syncs + decodes on next timer tick after link returns |
| UDB dies mid-rsync | Partial transfer; rsync resumes/completes on the next tick (`capture.done` gates eligibility, rsync handles partials) |
| Dongle wedged at AOS | Recovery ladder (service bounce → usbreset → bounce); failure recorded as `capture.failed`, ntfy'd by the rack |
| Pi reboot mid-pass | Units are enabled; that pass is lost (`.part` never promoted), next pass normal; stale `.part` dirs pruned by age |
| TLE stale (long outage) | Predictor warns at >7 d, keeps predicting from cache |
| Decode fails rack-side | Same as today (rc + log in the capture dir, ntfy); baseband retained per existing KEEP_IQ rules |

### Explicitly out of scope

- Decoding on the Pi (CPU reserved for GOES).
- Any change to the GOES pipeline, registry devices, or the gallery/tile UI.
- Fixing 137 MHz reception (antenna/RF chain — separate open issue).

### Prerequisites (provisioner-installed, install-if-absent)

- Pi: `pyorbital` for the predictor (`pip3 install --break-system-packages`,
  same as the .84 pattern) and `usbutils` ≥ the version shipping `usbreset`
  (present on the current image).
- Rack → Pi ssh: .84's sync unit needs a key authorized for `rgardner@goes.srvr`
  (same pattern .85's goes-pull already uses for the GOES rsync).

## Migration / rollback

- Deploy Pi units via `terraform taint 'module.pi_wxsat.null_resource.provision'`
  + apply; rack via the radio-compute taint. Order: Pi first (harmless — new
  units idle alongside the old rack scheduler), then rack (swap scheduler →
  sync timer).
- Rollback = re-enable `wxsat-scheduler.service` on .84 and disable the Pi
  scheduler; rtl_tcp path is unchanged so the old mode still works.

## Testing

1. **Pi capture, link up:** trigger a short dry capture (forced 60 s window) on
   the Pi; verify `baseband.cu8` + `pass.json` + `capture.done` and that
   rtl_tcp serves remote clients again afterwards.
2. **Link-down capture:** `iptables` drop (or physically pull) the Pi's uplink
   for the window; verify the capture completes locally and syncs + decodes
   within one timer tick of the link returning, with ntfy.
3. **Live view:** during a capture with link up, `/api/wxsat/live` on .84 shows
   spectrum/level/arc; with link down it reports `available: false`.
4. **Recovery ladder:** wedge simulation — stop-start rtl_tcp mid-connect and
   confirm retry; verify `usbreset` targets only the Meteor devnum.
5. **Prune:** back-date a capture dir >72 h, run the prune, confirm deletion
   and that the rack copy is untouched.
6. **Idempotence:** re-run wxsat-sync with nothing new — no re-decode, no
   duplicate ntfy.
