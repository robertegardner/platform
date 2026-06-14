# session_notes.md — SDR Platform V2 build log

Working notes per session, newest first. Full detail lives in
`deployment_notes.md` (results, runbooks) and git history; this is the quick
"where were we" index.

## 2026-06-14 (latest) — wxsat UI fix (proxy + delete), V2 cleanup pass

**State: V2 FM LIVE on .84, now STEREO + 256k. wxsat web UI now works on
radio.rg2.io; web-UI delete fixed.**

- **Stereo round 2 — SHIPPED (now the rack default).** Round-1 clicks were the
  38 kHz carrier recovery, not clipping: per-block RMS normalize stepped the
  carrier scale at block boundaries on a noisy pilot, and the normalized crest
  spiked to 3-4x → those transients hit L-R. Fix (radio repo `8d31428`): EMA
  carrier amplitude across blocks (--carrier-alpha), clamp the crest
  (--carrier-clamp 1.3), ramp the honesty-gate blend within the block. Offline
  A/B (decode_lib harness on /tmp/mpx.s16): identical to round-1 on a clean dump,
  12x fewer click transients on a buried-pilot stress case. Live A/B'd on 100.7:
  clean, RDS intact (PI 0x211E), no clip (peak 0.11), clamp fires ~0.01% (carrier
  clean). **Pilot-floor recalibrated 0.003 -> 0.0015** for the wbfm MPX scale
  (clean pilot ~0.0047; the 0.003 floor was carried over from the csdr path and
  was suppressing stereo to blend 0.29 / -37 dB). Now blend 1.0, separation
  -26.8 dB live (-23 dB content ceiling — modest but real; this station/reception
  just isn't very stereo). scale=2.0 for mono loudness parity. Baked into the
  radio-compute provisioner stream.sh + deploy.sh --rack now installs
  stereo_decode.py. **Revert to mono:** `cp /opt/sdr-tuner/stream.sh.mono.bak
  /opt/sdr-tuner/stream.sh && systemctl restart sdr-fm@active` on .84.
- **NOTE:** .84 load avg ~9 on 4 cores (steady, pre-dates stereo — not caused by
  the stereo pipeline, which adds ~0 measurable CPU). Worth a separate look.

- **wxsat UI was empty on radio.rg2.io.** Root cause: the V2 cutover repointed
  radio.rg2.io→.84, but wxsat captures live ONLY on the Pi (scheduler needs the
  SDR). Fix (radio repo `25993bd`, platform `3fae719`): `app.py` `before_request`
  hook proxies every `/api/wxsat/*` to `WXSAT_UPSTREAM` (Pi tuner, set in .84's
  tuner.env; new `pi_host` var in the radio-compute provisioner makes it
  re-provision-safe). The /wxsat page renders locally; only data+images+rebuild
  proxy. **Consequence: the Pi sdr-tuner is now the wxsat backend — NOT orphaned,
  do not retire it.**
- **Web-UI delete always failed (V1 too).** Access logs showed every real delete
  → 400 "missing id". Cause: the pass-view modal's "✕ Close" button shared
  `class="del"`, so closing it fired the delete handler with no data-id. Fix
  (radio repo `45d5553`): Close → `class="pv"` + guard the handler on data-id.
  Also delete now removes the canonical `outdir` (not the image's top dir), so
  FAILED captures' retained multi-GB baseband.cs16 is actually reclaimed (was
  orphaning ~3.7 GB each).
- **Offline re-decode of the 09:24Z 60° pass:** 0 frames at both 72k+80k (SNR
  0 dB, NOSYNC). IQ is NOT flat (mean|IQ|≈0.46) but band-center is at the noise
  floor with a strong birdie at −147.8 kHz → antenna/RF, not LNA-zero/decode. The
  06-13 antenna rework did NOT fix it.
- **256k bump (done).** .84 FM was 128k; bumped to 256k via the tuner's own
  /api/bitrate (live encoder now `-b:a 256k` on /fm.mp3, persisted in active.env
  + ui.json). **Pre-existing bug found+fixed:** .84's `/etc/sdr-streams` was
  `root:root 0755`, so the tuner (User=radio) got EACCES writing `ui.tmp` → EVERY
  UI settings save (bitrate, site title) silently 500'd. Fixed live
  (`chown root:radio` + `chmod 0775`, matching the Pi) and in the radio-compute
  provisioner so it's re-provision-safe.
- **Cleanup pass:** Pi `icecast2` confirmed idle (LISTEN, 0 inbound clients) —
  safe to retire (stop+disable), pending a manual run (classifier-gated; user to
  run `sudo systemctl disable --now icecast2` on the Pi). **Found:** Pi
  `scanner-transcribe.service` still enabled+running (V1 remnant pulling
  .82/ems.mp3 → Whisper) — flag for scanner-domain cleanup, not touched.

## 2026-06-14 (later still) — wxsat made V2-ready for the 09:24Z Meteor pass

**State: METEOR-M2 4 pass 2026-06-14 09:24Z (~60°, NORAD 59051) is software-ready.
Antenna optimized + LNA externally powered by the user; the V2 device-handoff gap
fixed + validated.**

- **Gap:** post-V2-cutover the dx-R2 is held by `sdr-source@dx-r2` (rack FM), but
  `wxsat_capture.sh` (runs as `radio`, borrows the dx-R2 Antenna B locally) only
  stopped the now-masked `sdr-fm@active` → `rx_sdr` would hit a busy device and the
  pass would fail.
- **Fix (radio repo `75bb5c0`):** capture script stops `sdr-source@dx-r2` before
  `rx_sdr` and restarts it after (+ cleanup trap); added a NOPASSWD sudoers grant
  for `radio` → start/stop/restart `sdr-source@dx-r2` (visudo-validated).
- **Validated:** 12s test capture as `radio` → `rx_sdr` acquired the dx-R2 (44 MB
  IQ), decode no-sync as expected (no sat overhead), source + .84 FM recovered.
  Scheduler armed (DRY_RUN=0, next_pass registered), TLE 59051 cached (~17h old).
- **Post-pass:** .84 `sdr-fm@active` self-heals onto the fresh source via
  `Restart=always` + `fm-watch.timer` (~1–2 min FM gap). Listener-skip gate: 4 AM
  local, ~0 human listeners → capture proceeds. Capture is now gated only on the
  physical antenna/LNA + a satellite actually being heard.

## 2026-06-14 (later) — rack UI deploy + single-station stereo attempt (mono kept)

**State: V2 FM still LIVE on .84, MONO. radio.rg2.io UI now current (viz+bitrate).
Single-station stereo attempted live, reverted to mono — a stereo-decoder DSP
artifact remains. No production left on stereo.**

- **Rack app deploy gap closed.** radio.rg2.io UI was stale (app.py from 2026-06-03,
  no viz/bitrate) because the rack had no deploy target (deploy.sh only did the Pi,
  and its stream.sh install would clobber the rack wbfm_stream.py chain). Added
  **`deploy.sh --rack`** (radio repo `a88ba91`): app payload only (python+templates+
  static viz JS+wbfm_stream.py), restarts sdr-tuner+sdr-captions, leaves audio up,
  SKIPS stream.sh + Pi-only units/sudoers. Cloned a checkout at **`/opt/radio-src`
  on .84** (anon HTTPS). Deployed → radio.rg2.io now serves viz + bitrate UI; audio
  untouched. Future rack deploy: `cd /opt/radio-src && git pull && sudo ./deploy.sh --rack`.
- **Single-station stereo (radio repo `111e8b9`, WIP — NOT in production).** Reused
  the multistation stereo matrix: `wbfm_stream.py` (s16le MPX) → tee → redsea +
  `stereo_decode.py` (added `--in-format s16le`/`--out-format f32le`) → ffmpeg
  (-ac 2, de-emphasis, alimiter). Decodes real stereo (L−R energy present, RDS
  intact). Chased clipping through several live iterations:
  1. Output too hot (max −1.4) → lowered scale → still clipped.
  2. int16 clip INSIDE stereo_decode: live true peaks hit **~4.3× full scale** (vs
     0.44 on the offline dump) → switched to `--out-format f32le` (no internal clip).
  3. ffmpeg `alimiter` default `level=enabled` auto-boosts output back to ~0 dB →
     added `level=false`.
  - After all that, output is provably clean digitally (max −4.2 dB) but the user
    STILL hears clicks → it's a **stereo-matrix DSP artifact**, not clipping: the
    L−R 38 kHz carrier normalization (`c38n = c38/c38_amp`) spikes on a noisy live
    pilot, injecting the 4.3× transients = clicks. **The offline dump (clean
    capture) does NOT reproduce it.** Reverted to mono (stable, clean).
  - **NEXT (offline, fresh session):** harden carrier recovery in stereo_decode
    (clamp c38n / floor c38_amp / stronger honesty gate), validate against a FRESH
    dump captured during spiky conditions, only then a single clean live test.
- **Ops note:** each live stream.sh swap restarts sdr-fm@active; rapid back-to-back
  restarts race the SoapyRemote source (one "no packets" crash-loop seen — the
  "restart source fresh between clients" gotcha). Do single restarts, settle ~20s.
  An auto-revert transient timer on .84 (`stereo-revert`, copies stream.sh.mono.bak
  + restarts) was used as the safety net for each live trial.

## 2026-06-14 — V2 RADIO CUT OVER (for real): the bug was rx_fm, NOT UDP

**State: V2 radio LIVE on .84 via `wbfm_stream.py` over the remote dx-R2 (lossless
TCP). Clean audio + rich RDS confirmed by the user. radio.rg2.io → .84:8080. The
Pi is a pure acquisition node again (sdr-fm@active masked, sdr-source@dx-r2
enabled). The 2026-06-13 root-cause ("UDP IQ loss garbles FM") was WRONG.**

- **Re-diagnosed from scratch in attended windows.** Brought V2 up on the live
  /fm.mp3 over the committed TCP fix (b9049c5): user heard the SAME garble, RDS
  dead — but the IQ socket was provably **TCP** (ss: ESTAB, zero UDP to .84).
  So TCP-lossless did NOT fix it ⇒ UDP was never the (whole) cause.
- **Isolation chain that found the real bug:**
  1. `capture-iq.py --prot tcp --dump` (full-speed consumer, no tee) → 240 MB IQ,
     0 overflow/0 timeout, CLEAN.
  2. Wrote `tools/demod-iq.py` (numpy WBFM, no scipy) and demodded that dump
     offline → **336 RDS groups**. So the TCP IQ itself is perfect.
  3. First hypothesis was live-pipeline backpressure (tee→redsea stalling rx_fm →
     server-side overflow). Added mbuffer decoupling to stream.sh → **still no
     RDS**. Hypothesis wrong.
  4. Decisive test: `rx_fm`(remote,TCP) → redsea **direct** (no tee/ffmpeg/mbuffer)
     → **0 RDS groups**. Same IQ, my demod gets 336, rx_fm gets 0 ⇒ **rx_fm itself
     mangles the SoapyRemote stream** (mishandles the ~1006-sample MTU partial
     reads → broken FM demod continuity → clicks + dead RDS). Exactly why
     am_stream.py already replaced rx_fm for AM.
- **Fix = `wbfm_stream.py`** (radio repo `files/opt/sdr-tuner/`, commit 8157efe):
  a SoapySDR WBFM+RDS client (capture-iq's stream setup + demod-iq's proven demod)
  that reads IQ directly, accumulates reads phase-continuously, emits the same
  250k s16le MPX rx_fm did — drop-in for the tee→redsea/ffmpeg chain. Forces
  remote:prot=tcp. Bench: `wbfm_stream.py | redsea` direct → rich RDS
  (PI 0x211E / PS KGMO); full stream → now_playing populated; retune 100.7↔99.3
  cycle good; user listen = CLEAN.
- **Cutover executed** (attended, dead-man armed each window): .84
  `sdr-fm@active`(enabled)+`sdr-tuner`+`sdr-captions`+`fm-watch.timer` up; Pi
  `sdr-fm@active` masked, `sdr-source@dx-r2` enabled+active, `pi-fm-watch.timer`
  + `sdr-captions` disabled. NPM `radio.rg2.io` → 192.168.6.84:8080. Verified:
  public UI 200 + now_playing/lyrics, /fm.mp3 200, RDS fresh, captions writing.
- **Lessons:** RDS is the cheap pass/fail (audio-level/astats can't see garble).
  "Clean transport" (0 overflow/timeout) is necessary-but-not-sufficient AND can
  be measured on a path the live client still wrecks — always A/B the actual
  client vs a known-good demod. rx_fm is unfit as a SoapyRemote streaming client.
- **Open/non-blocking:** stream is 128k mono (V1 was 256k — bump via UI
  /api/bitrate if wanted); rx_fm build + RX_STREAM_ARGS patch kept in the
  provisioner but now unused by the FM path; mbuffer was apt-installed on .84
  during diagnosis (harmless leftover, not used by the final stream.sh);
  **the Pi sdr-tuner must STAY — as of 2026-06-14 it is the wxsat backend (the
  .84 tuner proxies /api/wxsat/* to it; see the 2026-06-14 wxsat session note);
  do NOT clean it up;** Android-app no-audio is a separate pre-existing issue.

## 2026-06-13 (evening) — Radio-domain antenna triage (wxsat fail + dead AM); two physical fixes pending

**State: still V1-hybrid. No code or deploy changes — two physical-layer antenna
faults diagnosed, both deferred by the user to the next attic trip (after the
next sat pass or when the Airspy R2 arrives). Diagnoses recorded so a future
session doesn't re-derive them.**

- **wxsat pass "failed again" — receiver fine, no signal.** Both 2026-06-13
  Meteor-M2 4 passes (max 34° and 28°) recorded `failed`: full **3.66 GB**
  baseband captured, but SatDump decoded **0 CADU frames** (SNR 0 dB,
  Viterbi/Deframer NOSYNC, BER ~0.40 noise floor; 0 MSU-MR lines). PSD of the
  baseband (no DC offset, in-band only ~3 dB over the edges, one off-grid spur
  at −151 kHz) confirmed **no LRPT carrier present** — acquisition healthy, the
  satellite just wasn't heard.
- **Root cause = unpowered LNA on the wxsat path.** Capture runs on the **dx-R2
  Antenna B** (`wxsat_capture.sh:162`, "dipole + Sawbird+ NOAA LNA"), NOT a
  dedicated RTL v4 — registry marks ports B/C "physical-readiness only." That
  `rx_sdr` line passes **no bias-T**, and the bias-T automation (platform agent)
  targets the *RTL v4*, not this dx-R2 path → the Sawbird ran unpowered.
  **User powered the LNA externally** and is repositioning the dipole
  (~53 cm legs, 120° V, horizontal, **apex North** = N–S axis for the polar
  track). Validate on the **2026-06-14 09:24Z, 60° overhead** pass. Code fix
  still available if wanted: `rx_sdr -d "driver=sdrplay,biasT_ctrl=true"`.
- **AM (Antenna C) dead feed.** User added a choke to the AM loop today → static;
  reverted to the long wire → still static even on 960 (KSIM local). am_stream.py's
  startup RFI scan (`/run/sdr-streams/rfi_status.json`) at 960 kHz:
  **station_snr −1.44 dB** (carrier *below* noise floor), KMOX 1120 / all grid
  stations absent, only off-grid birdies (1195/1205/1635 kHz) = the
  "antenna-disconnected" signature. Receiver + DSP confirmed nominal in the same
  log (HDR engaged, DAB notch on, broadcast `rfnotch` correctly OFF, PLL locks,
  Antenna C selected). Fault is **common to both the loop+choke and the long
  wire** → the shared connection the user changed today: **prime suspect the
  choke / disturbed SMA**. Next attic trip: bypass-test the choke (bare wire to
  Antenna C) — a local should jump +30–50 dB; scan re-runs on every
  `systemctl restart sdr-fm@active`.

## 2026-06-13 (late afternoon) — V2 CUTOVER ROLLED BACK: UDP IQ garbles analog FM

**State: back on V1-hybrid (FM DSP on the Pi), web audio + RDS clean. The V2
cutover below was REVERTED hours later — the IQ gate is necessary but NOT
sufficient for analog FM.**

- Users heard **garbled, unlistenable** FM after the cutover (web + Android).
  First red herring: chased ADC gain/clipping (IQ measured clean, ~0.20, 0%
  clip) and a stale post-test source (ordered bounce helped levels but not the
  garble). astats said "clean" — misleading; it can't see dropouts/garble.
- **ROOT CAUSE (spectrogram from codeserver showed ~9 broadband clicks/s):
  SoapyRemote streams IQ over UDP** (confirmed: :55001 control is TCP, the
  sample flow is a UDP socket). Analog FM demod can't tolerate the packet loss
  — each lost IQ datagram = a click; **RDS dies** (dead on V2, decodes cleanly
  on V1 — the sensitive tell the user flagged). P25/CU8 survives (digital/FEC),
  which is why the same transport passed the IQ gate. The IQ gate only counts
  overflow/timeout, NOT UDP sample loss.
- Tried forcing `remote:prot=tcp` via rx_fm `-d` device args → rx_fm does NOT
  forward it to setupStream; the stream stalled (0 bytes / hang). So the V2-TCP
  fix needs a stream-arg-capable client (or a SoapyRemote-level config),
  bench-verified.
- **ROLLBACK (done):** .84 FM units disabled; Pi `sdr-fm@active` unmasked+started
  (local sdrplay, 100.7 KGMO), `sdr-source@dx-r2` disabled, captions+pi-fm-watch
  re-enabled; NPM `radio.rg2.io` → radio.srvr:8080. Web audio + RDS confirmed
  clean by the user. **V2 retry gate: lossless IQ transport + RDS-decode + a
  listen on the bench BEFORE re-cutover. RDS is the cheap pass/fail signal.**
- **SEPARATE, still open — Android app: no audio / no viz / no captions** (title
  still updates), duck on or off. Not the cutover (present on V1 too) and not the
  duck (toggle no-op). All three are tap-derived → the app's **ExoPlayer isn't
  playing `https://icecast.rg2.io/fm.mp3`** (browser plays it fine). Needs a
  logcat to pinpoint (ICY-metadata parse? recent AudioTapHub/playback regression
  in radio-android?). Stream URL is correct (`RadioSettings.DEFAULT_STREAM_URL`).

## 2026-06-13 (afternoon) — V2 RADIO CUT OVER: FM DSP back on .84

**State: V2 radio LIVE. The attic uplink going 2.5G unblocked the IQ-microburst
contention that forced the rollback. All three re-rollout gates + a 14-min soak
PASS. radio.rg2.io repointed to .84.**

- **What changed physically (user):** new port + cable on the Attic Camera Flex
  switch → Pi eth0 back to **1000FDX autoneg ON** (100FDX force gone), stable
  (0 new flaps over ~6 h incl. warm afternoon). AND the switch's **uplink moved
  to a 2.5G port** (10GE-capable, links 2.5G; 10G planned w/ fiber later) —
  raising the shared-uplink ceiling 1G→2.5G. That ceiling lift is what made V2
  viable; the dedicated attic run is now nice-to-have, not required.
- **Gates (deployment_notes "V2 radio RE-ROLLOUT runbook"):**
  - Flap: 0 new events (boot-bounce only) over the warm window. PASS.
  - Loss: iperf UDP Pi→.84 — 64/102M = 0%, **256M = 0.0019%** (<0.01% gate; was
    0.03% on the 1G uplink). 400M = 1.2% (ceiling above V2 rate; Pi 1G egress /
    LXC rx buffers, not the 2.5G uplink). PASS.
  - IQ: `tools/capture-iq.py` from .84 — 2 Msps CLEAN; **8 Msps × 120 s, 0
    overflow / 0 timeout, 255 Mbps**. PASS (the real V2 test).
- **Cutover executed (runbook steps 2–8):** used a 15-min systemd-run dead-man
  while testing; disarmed it first thing at cutover. Pi: `sdr-fm@active` masked,
  `sdr-source@dx-r2` enabled+active (:55001), `pi-fm-watch`+captions disabled.
  .84: `sdr-fm@active`/`sdr-tuner`/`sdr-captions`/`fm-watch.timer` enabled+active.
  Tune cycle 99.3 (KCGQ-FM) ↔ 100.7 (KGMO) verified via `/api/tune`; resting on
  **100.7 KGMO** (primary), mount audio mean ~-22/max ~-10 dB. Soak 9/9 mount=200,
  0 stream errors. NPM: `radio.rg2.io` → .84:8080 (verified now_playing through
  the public URL). icy-pusher follows automatically; fm-duck unaffected.
- **POST-CUTOVER FIX — FM distortion (same day):** users reported "very
  distorted" FM after the cutover. NOT gain/clipping (remote IQ measured clean,
  mean|IQ|≈0.20, 0% clip at every gain incl. AGC) and the .84 vs Pi `stream.sh`
  FM pipelines are functionally identical. ROOT CAUSE: at cutover I `enable`d
  `sdr-source@dx-r2` for the IQ-gate test, ran capture-iq at 2 AND 8 Msps
  against it, then connected .84's LIVE rx_fm to that **same un-restarted
  source instance** — the test runs left the sdrplay session in a degraded
  rate/state that served subtly-bad IQ (audible distortion, normal levels).
  FIX = the ordered bounce (restart `sdr-source@dx-r2` on the Pi → reset-failed
  + restart `sdr-fm@active` on .84). Verified clean + stable (Flat factor 0,
  no clipping) across multiple samples; restored to 100.7 KGMO. **Lesson: after
  ANY capture-iq/IQ testing against a source, restart that source fresh before
  pointing a live client at it.** Added to the runbook + gotchas.
- **Open / non-blocking:** RDS ps/rt decode null on .84 (redsea-on-.84 follow-up
  — captions+FCC carry now_playing); stream is **128k mono** via the UI
  `/api/bitrate` setting (bump if V1 was 256k); UI AM/HD tune still stops the
  rack stream (stream.sh exit 78) until an FM retune; Pi `sdr-tuner` left running
  but orphaned (radio.rg2.io no longer points at it — harmless, optional cleanup).

## 2026-06-13 — Interim antenna farm recorded (registry only, no deploy)

**State: still V1-hybrid; Airspy R2 + RTL v4 enroute (not yet here). sdrplay
(dx-R2) + nooelec (rtl-2838) remain the only live tuners.** Recorded the
current physical antenna assignments in `terraform/registry/devices.json`:

- **dx-R2 (sdrplay, RSPdx-R2 — single tuner, 3 software-selectable inputs):**
  added an `_antenna_ports` map. **A** = Shakespeare 5120 + FM bandpass
  (active FM job, unchanged); **B** = dipole + Sawbird+ NOAA (LNA) — interim
  NOAA/Meteor, role slated for `rtl-v4`; **C** = AM loop + inline choke —
  interim AM broadcast, role slated for `hf-plus`. One band at a time, so B/C
  are physical-readiness only while V1-hybrid FM owns the device.
- **rtl-2838 (nooelec):** `filter` `none` → `Flamingo FM band-stop` on the
  discone (matches what `airspy-r2` inherits on arrival).
- Underscore-prefixed key + descriptive `filter` only — provisioner
  (`present: true` iteration) untouched, no `terraform apply`.

## 2026-06-12 (evening) — Duck/ICY stack validated on-air; flap gate PASS

**State: 100FDX interim holding (flap gate: 0 events / 4.5 h incl. warm
evening). fm-duck + icy-pusher live and validated against a real ad break.**

- **On-air validation (19:38 CDT):** track-ID cleared → classifier ducked
  (score 0.32; beat collapsed to 0.00 — the talk signature) → ICY marker
  "KGMO 100.7 at commercial" swapped within 1 s → un-duck 29 s later →
  one song (~4 min) → next break ducked. Working as designed.
- fm-duck classifier needed SERVER-calibrated scales (HF_FULL 0.20,
  CV_FULL 1.20) — client constants don't transfer to linear-PCM rfft
  magnitudes (music sat at 0.36–0.47 and nothing ever ducked). Probe +
  component heartbeats are the tuning loop (`journalctl -u fm-duck`).
- **wxsat skip-when-listening fixed (radio repo fcabdb5):** the gate
  queried the Pi's icecast (always 0 since the cutover → captured despite
  listeners). Now queries the RACK (env-able WXSAT_ICECAST_STATUS) and
  discounts the fm-duck relay (detected via its mount in the same payload).
  Live-verified: raw=3 internal=2 human=1.
- One isolated publisher TCP reset (19:21 CDT, link clean) self-healed
  end-to-end in ~100 s: pi-fm-watch → sdr-fm restart → fm-duck reconnect →
  ICY re-latch. The recovery chain works.
- **Tomorrow / open:** duck-tuning v2 on Android needs a sideload
  (radio-android 740ddf5); dedicated attic run still the real fix (V1
  reliability + V2 unpause); optional duck v3 = fuse now_playing hints
  (captions/track-ID) to kill the music-bed-commercial blind spot;
  consider liquidsoap-wrapping fm-duck if WiiM doesn't auto-reconnect
  across Pi tunes.

## 2026-06-12 (afternoon) — Attic link DIED outright (escalation of the flap saga)

**State: Pi OFFLINE/bouncing pending physical fix. Both public streams were
silent ~14:40 CDT.** The thermally-marginal link (network_health.md root-cause
item 4) escalated from flapping to hard failure during peak attic heat:

- Symptom: web player "playing" but silent; Android stream dead. Cause:
  `/fm.mp3` source lost on the rack (Pi stream.sh: "Network is unreachable");
  Pi unreachable. UniFi showed the port with **no ethernet client but 10 W
  PoE draw** — wedged PHY, Pi still powered/running blind.
- PoE power-cycle (user) → reboot → 3–7 s link flap burst for ~1 min
  (`macb eth0: Link is Down/Up - 1Gbps/Full`) → ~60 s stable → **dead again**,
  then bouncing (pingable in bursts, SSH times out).
- Next actions (physical, in order): try a DIFFERENT port on the attic switch
  (isolates port vs cable vs Pi PHY/HAT); reseat both cable ends; stopgap =
  force the port to **100FDX** (2-pair — marginal-at-gigabit cables often run
  clean; V1-hybrid traffic incl. the scanner CU8 ~38 Mbps fits).
- Verdict: the **dedicated attic ethernet run is now required for V1
  reliability**, not just the V2 unpause.
- **RESOLUTION (interim, ~15:15 CDT): port forced to 100FDX (user)** → link
  immediately held (3+ min continuous, vs seconds at 1G) — confirms the
  marginal-at-gigabit medium. One leftover: a flap had killed ffmpeg's TCP
  to the rack mid-publish ("Connection reset by peer") leaving
  `sdr-fm@active` active-but-publisher-dead; **`pi-fm-watch` caught it**
  (~2 min detection) and restarted the unit; both mounts back, /fm.mp3 200.
  Leave the port at 100FDX until the dedicated run exists. Re-check the
  flap gate over a warm-afternoon window before trusting it.
- Same day, unrelated: Butterchurn visualizer shipped in radio.html (radio
  repo), native projectM MILKDROP + duck-on-talk shipped in radio-android.
- **fm-duck shipped (distribution, .82):** server-side talk-ducked relay
  `/fm.mp3` -> `/fm-duck.mp3` (`fm-duck.service`, decode->classify->gain->
  re-encode; same v2 classifier as the web/Android duck) so GUI-less
  streamers (WiiM) duck by URL choice. Provisioned via the distribution
  module (fm_duck.py + unit + root-only env w/ source password); the
  provisioner now restarts icecast2 ONLY on fresh config (re-provisions no
  longer drop listeners/the Pi publisher). Registry: /fm-duck.mp3 added.
- **icy-pusher shipped (distribution, .82):** now-playing -> ICY StreamTitle
  on /fm.mp3 + /fm-duck.mp3 (polls https://radio.rg2.io/api/now_playing —
  follows the backend across the V2 unpause — and pushes the Icecast admin
  metadata endpoint on change, per-mount latched so a reconnecting mount
  catches up next poll). WiiM and other network streamers now display
  Artist - Title natively; ICY-ignoring clients unaffected. Follow-up:
  while fm-duck reports talk, the duck mount's StreamTitle becomes a
  "— commercials / talk (ducked) —" marker (fm-duck publishes state to
  /run/fm-duck/state via RuntimeDirectory; stale >180 s = music; verified
  by faking the state file — marker push + title restore both observed).

## 2026-06-10 — DAY SUMMARY (for the next session)

One very long day: compute tier built and both domains cut over → GUIs moved
→ a cascade of real faults found and fixed (remote-exec masking, grep -q
SIGPIPE, TUNER gain, liquidsoap mksafe, op25 http sys.exit, -U port bind,
wlan0 ARP flux, ffmpeg CLOSE-WAIT zombies, watchdog curl-28) → final boss:
the attic camera flex's shared 1G uplink tail-drops SoapyRemote's line-rate
IQ microbursts → **V2 radio PAUSED, V1-hybrid restored** (Pi DSP →
rack Icecast; verified). Scanner remains V2 and healthy. END STATE + NPM map
in CLAUDE.md; full evidence chains in deployment_notes.md. Unpause trigger:
the dedicated attic ethernet run. Commits this day: ece97b2…740c818
(platform), a70253d (radio repo, branch fix-fm-device-loss-selfheal —
stream.sh ICECAST_HOST, needs merge).

## 2026-06-10 (late night) — V2 radio PAUSED: V1 hybrid restored

**State: FM DSP back on the Pi, publishing to the rack Icecast (0.25 Mbps
paced TCP — the V1 traffic profile). Public /fm.mp3 200 via NPM→.82.
Scanner stays V2. User decision after the transit-loss root cause.**

- Root cause of the unusable V2 FM audio (via UniFi controller DB): the Pi
  shares the attic camera flex with 8 cameras (~124 Mbps) + an HDHomeRun;
  the flex's 1G uplink tail-drops SoapyRemote's line-rate IQ microbursts
  (cameras = paced TCP, unaffected; ICMP clean; V1 audio = 0.5 Mbps, never
  noticed). Neighbor link is 1G by design — not a negotiation fault.
- Restore: rack FM units disabled (.84 stays fully provisioned); Pi
  sdr-fm@active unmasked/enabled, sdr-source@dx-r2 disabled, stream.sh
  publish host env-able (ICECAST_HOST=192.168.6.82; mirrored to the radio
  repo, branch fix-fm-device-loss-selfheal). Pi captions re-enabled.
- **Unpause trigger: dedicated attic run to the aggregation switch** (user
  plans a new pull). Then re-cutover = the documented switch steps; also
  consider `tc fq maxrate` pacing on the Pi as belt-and-braces.
- Post-restore addendum: the V1 publish chain stranded once on a transient
  path blip (ffmpeg output error wedges the pipeline half-alive — no
  pipefail in stream.sh's inner shell). Installed `pi-fm-watch.timer` on the
  Pi (same 2-strike mount watchdog as .84's; script at
  /usr/local/sbin/pi-fm-watch.sh, marked platform-cutover). Belongs in the
  radio repo long-term, alongside merging branch fix-fm-device-loss-selfheal.

## 2026-06-10 (night) — RDS verdict + radio GUI on the rack

**State: sdr-tuner UI live at 192.168.6.84:8080 (V1 contract, app.py
unmodified); captions orchestrator moved to .84; RDS closed as no-defect.**

- RDS A/B: rack chain decodes KGMO 100.7 richly; 99.3 fails even via the
  Pi's local rx_fm — that station's RDS is just weak (V1 only ever had
  PI+PTY). rds_watcher now runs in the rack pipeline (now_playing.json).
- Replaced interim fm-stream contract with V1 sdr-streams contract on .84
  (active.env + sdr-fm@active + stream.sh wbfm-only, exit 78 for HD/AM).
  App code deployed from the radio repo checkout; station data copied from
  the Pi; sdr-captions runs rack-side now (Pi instance disabled).
- Scanner GUI = op25 console at .83:8080. NPM (user): radio.rg2.io → .84:8080,
  scanner.rg2.io → .83:8080.
- Ops gotcha recorded: wedged dx-R2 source needs the ordered bounce
  (stop client → restart sdrplay + source on Pi → reset-failed + start client).

**Next:** radio repo v2 (stereo mux; HD/AM rack-side; deploy-to-rack target
in its deploy.sh); scanner v2 on R2 arrival; NPM repoint last.

## 2026-06-10 (evening) — Radio domain cut over: FM LIVE on the rack

**State: the Pi is now a pure acquisition node. Both audio domains decode
rack-side; all V1 DSP services on the Pi are retired (sdr-fm@active masked).**

- radio-compute gained rx_tools + redsea (toolchain) and `fm-stream.service` —
  the exact V1 stream.sh FM pipeline against `driver=remote` dx-R2 (sdrplay
  decimates server-side; ~1 MB/s wire). RDS lands in rds-latest.json.
- Cutover with dead-man; `sdr-source@dx-r2` enabled at boot; Pi `/fm.mp3`
  on-demand relay added (NPM was reverted to the Pi after an early repoint
  broke /fm.mp3 — public names work through the two Pi relays until the
  proper NPM repoint, which then retires the relays + Pi icecast).
- Interim: tuner-UI retune/HD/AM dead (retune = fm.env edit on .84);
  multistation stereo mux remains the radio repo's v2 project, now with a
  ready rack target.
- NEW: codeserver has rsync (user installed) — tar-over-ssh no longer needed.

**Next:** radio repo v2 (stereo mux per MULTISTATION_STEREO_BUILD plan,
targeting .84); scanner v2 app on R2 arrival; NPM repoint LAST (removes
relays, disables Pi icecast).

## 2026-06-10 (later) — Compute tier built, P25 LIVE on the rack

**State: re-sequenced (compute before radio hardware). op25 on scanner-compute
decodes MOSWIN; /ems.mp3 rack-sourced; Pi throttle gone (load 0.4, 61 °C).**

- Built `scanner-compute` (LXC 901/.83) + `radio-compute` (LXC 902/.84) for
  real: full provisioning (op25 gr310 build + gr-osmosdr/soapy verify +
  liquidsoap chain; csdr/nrsc5/SatDump toolchain). Registry-rendered client
  envs are ALWAYS rewritten → Airspy R2 / HF+ / RTL v4 join via registry flip
  + re-apply (active scanner source flips automatically: airspy-r2 sorts
  before rtl-2838).
- Added interim `rtl-2838` registry device (SoapyRemote CU8 @ 2.4 Msps, port
  55005) — same transport the R2 will use. Pi: SDRTrunk retired
  (`SCHEDULER_EMS_DEFAULT=false`), `sdr-source@rtl-2838` enabled at boot,
  Icecast on-demand relay keeps public `/ems.mp3` alive.
- Verified end-to-end: P25 Phase II voice following + real audio on
  `icecast.rg2.io/ems.mp3`; `/fm.mp3` untouched throughout.
- Interim dark: `/ems-{fire,police,interop}`, `/monitor.mp3`, EMS call
  transcripts (scanner v2 app work restores them on R2 arrival). Full record
  + rollback + new gotchas (remote-exec masking! grep -q SIGPIPE! TUNER gain!)
  in `deployment_notes.md`.

**Next:** when the Airspy R2 arrives — flip registry (airspy-r2 true,
rtl-2838 false), re-apply, retune op25 config; scanner v2 app work (multi-mount,
monitor, transcripts). Radio domain per the existing plan; raise
rmem_max/wmem_max on THEBEAST (host kernel) before any >5 Msps stream into an
LXC.

## 2026-06-10 — Distribution tier stood up (no cutover)

**State: rack Icecast LIVE at 192.168.6.82 (LXC 900). Production untouched.**

- Built `module.distribution` (container + provision, copied from
  homelab-monitor's `module.monitoring`) and `terraform/registry/mounts.json`
  (V2 audio namespace + legacy Pi mounts with their migration phase).
- Verified end-to-end: ffmpeg test source from the Pi → `/test.mp3` on the rack
  Icecast → listener pulled valid MP3 → mount cleaned up. Idempotent re-provision
  (icecast.xml marker guard, byte-identical).
- Same source password as the Pi's Icecast (tfvars on thebeast only) — future
  source cutovers change only the host.
- **Deliberately not done:** NPMplus repoint, Pi source changes, anything
  scanner. Cutover runbook in `deployment_notes.md`.
- Gotchas: deploy token lacks `Pool.Allocate` (no pools — tag-identified);
  LXC SSH needs `id_rsa_homelab` (the injected key; `id_ed25519` only works on
  the Pi); bpg modules need their own `required_providers`.
- Commits: `9a1edd0` (scaffold), `ee3104a` (live + runbook). Pushed; tree synced
  to thebeast.

**Next:** `scanner-compute` (.83/vmid 901) when the Airspy R2 arrives →
`radio-compute` (.84/902) → NPMplus repoint last. Flip the registry device
`present: true` + re-apply to join each new tuner.

## 2026-06-09/10 — Phase 0: scaffold + dx-R2 transport proof → **GO**

**State: Gate 0B GO. SoapyRemote 8 Msps CS16 proven Pi → rack.**

- Phase 0A: Terraform scaffold (bpg/proxmox per homelab-monitor), device
  registry (`terraform/registry/devices.json`, only dx-r2 `present: true`),
  `pi-acquisition` module (null_resource + remote-exec, NO container).
  Commit `ece97b2`.
- Phase 0B first attempt: 8 Msps stalled after ~6 s → NO-GO recorded
  (`4ed4e52`). 2.5 Msps clean with real signal (KGMO carrier +13.7 dB).
- Tuning window: root cause = kernel socket buffers (Pi at 4 MB default;
  SoapyRemote wants ~100 MB — its sysctl drop never applies post-boot). Fixed +
  encoded in `provision-pi.sh.tpl`. Re-test: 120 s @ ~7.9 Msps, 0 overflows,
  0 timeouts → **GO** (`f27a4ce`).
- Local USB sanity passed (dx-R2 ~7.9 Msps on the Pi) — co-resident RTL2838 is
  a non-factor.
- Carry-forwards: client must pass `remote:driver=sdrplay`; default gain
  saturates the ADC at 8 Msps (compute sets gain at connect);
  `sdr-source@dx-r2` stays disabled (single-client vs live radio — attended
  windows only, dead-man timer pattern in `deployment_notes.md`).
- Live radio (`sdr-fm@active` / `icecast.rg2.io/fm.mp3`) restored and verified
  after every window.
