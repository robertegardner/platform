pt — FM Stereo + Multistation (radio project)

**Target repo:** `robertegardner/radio` (`/srv/radio` on the Pi, deploys to `/opt/sdr-tuner`)
**Tool:** Claude Code on the Pi, over SSH in tmux.
**Read first:** this repo's `CLAUDE.md` and the project's `PROJECT_MEMORY.md`.

This supersedes the backburnered "FM stereo via csdr/SoapySDR" item. Stereo and
multistation are one piece of work: the refactor that frees us from `rx_fm`'s mono
demod (capture raw IQ, run our own demodulator) is exactly what multistation needs.
Once we demodulate from our own IQ stream, **stereo is a property of the demod stage**
and **an extra station is another instance of that stage reading the same stream.**

---

## Locked parameters (do not re-derive)

| Parameter | Value | Why |
|---|---|---|
| Antenna | dx-R2 **Antenna A** (Shakespeare 5120) | FM only |
| Tune center | **98.0 MHz** | Midpoint of the wanted set |
| Capture sample rate | **8.0 Msps** (CF32) | ±4 MHz = 94–102 captured; keeps the advertised edges out of ADC/AA-filter rolloff |
| SDRplay IF bandwidth | **8 MHz** | Match the capture rate |
| Advertised window | **95.0–101.0 MHz** (6 MHz) | KGMO 100.7 sits at +2.7 of ±4.0 (67% Nyquist — clean); 95.7 at −2.3 |
| Max simultaneous channels | **4** | Naive one-worker-per-station; no channelizer needed at this count |
| Per-channel decimation | **/32 → 250 ksps** composite (MPX) | Full 0–60 kHz multiplex + guard; rejects ±200 kHz adjacent |
| Audio out | **48 ksts stereo, MP3 192k** (mono channels 128k) | Per the earlier stereo-bitrate note |
| RDS | **primary always; others toggle** | redsea per channel costs CPU; opt-in on non-primary |
| Captions | **primary mount only** | Per-channel Whisper is out of scope (CPU) |

Stations outside 95.0–101.0 are **not tunable in this mode** and must be greyed out in
the UI, not silently failed. AM is **not** in this window and never shares it.

---

## Hard invariants (bail-out conditions)

1. **Never leave the radio permanently down.** The legacy mono path (`stream.sh` →
   `sdr-fm@active` → `/fm.mp3`) stays the deployed default through Phase 1. A/B testing
   that requires stopping `sdr-fm@active` is fine **in an attended window only**, and the
   default end-state of any failure is `systemctl stop sdr-mux sdr-iq-capture && systemctl
   start sdr-fm@active` — back to known-good mono. If you can't guarantee that rollback,
   stop and report.
2. **Single device, mutually exclusive uses.** The dx-R2 can be opened by exactly one
   process. The new capture daemon, the legacy `sdr-fm@active`, AM tuning, and the wxsat
   SatDump capture **all contend for the same device.** The mux is the *FM-multistation
   mode* and is mutually exclusive with all of them — same coordination rule
   `sdr-fm@active` already lives under. Do not run capture concurrently with any of them.
3. **Don't touch the scanner.** Nothing in `/srv/scanner` or `/opt/scanner`. Shared Pi,
   separate everything else.
4. **Stereo honesty gate (per channel).** The L−R subcarrier lives at 38 kHz where SNR is
   worst; weak stations sound *worse* in stereo. **Do not ship a channel in stereo if it
   sounds worse than mono.** Strong locals (100.7) get stereo; distant affiliates default
   to mono. Implement an auto-blend-to-mono on low pilot SNR if cheap; otherwise per-channel
   config flag.
5. **Overload watch.** Capturing 6 MHz means *every* in-band signal hits the ADC at once —
   higher aggregate power than single-station, so more overload risk. Do **not** engage the
   FM-band notch (it kills the band we want). Set gain for the aggregate, verify no ADC
   overload on the strongest local, and treat visible overload as a Phase 1 stop.
6. **CPU ceiling.** Measure under 4-channel load. If it threatens radio stability or
   starves the scanner on the shared Pi, that's a Phase 2 stop — drop max channels or move
   to the channelizer (out of scope here).
7. **csdr is a hard dependency.** The wideband per-channel mix/decimate/demod must run in
   csdr (C/SIMD), **not** numpy — a real-time 8 Msps mix in Python will not hold. If csdr
   won't build on Trixie, **stop and report**; do not silently substitute GNU Radio.

---

## Architecture

```
dx-R2 (Antenna A) ── SoapySDR (driver=sdrplay) ──┐
                                                  │  8 Msps CF32, fc=98.0 MHz
                                          ┌───────▼────────┐
                                          │  iq_capture.py │  owns the device
                                          │  → UDS fanout  │  nonblocking, drops slow consumers
                                          └───────┬────────┘
                         ┌────────────────────────┼────────────────────────┐
                         │ (full IQ to each)       │                        │
                  ┌──────▼──────┐           ┌──────▼──────┐          ┌──────▼──────┐
                  │  channel 1  │   ...up    │  channel N  │   ...     │ (≤4 total) │
                  │ csdr: shift │   to 4     │             │          │            │
                  │  → /32 dec  │            └─────────────┘          └────────────┘
                  │  → fmdemod  │
                  └──────┬──────┘  composite (MPX) 250 ksps
                  ┌──────┴───────────────┐
                  │                       │ (tee, optional)
          ┌───────▼────────┐       ┌──────▼──────┐
          │ stereo_decode  │       │   redsea    │ primary always / others on toggle
          │ (numpy pilot   │       └──────┬──────┘
          │  PLL + matrix  │              │
          │  + 75µs deemph │      rds_watcher → now_playing-<mount>.json
          │  → 48k stereo) │
          └───────┬────────┘
            (mono path skips stereo_decode: 15k LPF + deemph + resample)
                  │
          ┌───────▼────────┐
          │ ffmpeg → MP3   │ 192k stereo / 128k mono
          └───────┬────────┘
                  ▼
          Icecast mount  e.g. /m100_7.mp3   (primary also aliases /fm.mp3 in Phase 2)
```

**Supervisor model** (departs from the env-file + `systemctl restart` model — justified
because managing 1 capture + up to 4 dynamic pipelines via templated units gets fiddly
around the shared IQ-socket lifecycle):

- `sdr-iq-capture.service` → `iq_capture.py` — owns the device, publishes IQ on a Unix
  socket. Started/stopped as a unit; the mux `Requires=` it.
- `sdr-mux.service` → `mux_supervisor.py` — reads `/etc/sdr-streams/channels.json`,
  launches/reaps one `channel_pipeline.sh` per active channel, reloads on `SIGHUP`.
- Flask still **never touches the device**: it writes `channels.json` and signals the mux.
  (Same spirit as the existing write-env-and-restart rule.)

**New files** (`files/opt/sdr-tuner/`):
`iq_capture.py`, `mux_supervisor.py`, `stereo_decode.py`, `channel_pipeline.sh`.
**New config:** `/etc/sdr-streams/mux.env` (center, fs, window, gain), `channels.json`
(active channels: `freq`, `mount`, `stereo`, `rds`, `primary`).
**New run state:** `/run/sdr-streams/mux_status.json`, `now_playing-<mount>.json`.
**New units:** `sdr-iq-capture.service`, `sdr-mux.service`.

---

## Phase 1 — single-channel stereo through the IQ path

**Goal:** validate the riskiest new components (SoapySDR capture + csdr front-end + numpy
stereo decode) at the lowest blast radius, with legacy mono still live as fallback.

**Scope:**
- `iq_capture.py`: open dx-R2 (`driver=sdrplay`), Antenna A, fs=8e6, fc=98e6, IF BW 8 MHz,
  conservative gain; activate CF32 stream; publish frames to a UDS fanout (nonblocking
  send, drop on `EWOULDBLOCK`). One subscriber for now.
- `channel_pipeline.sh` (hardcoded to **100.7** for this phase): csdr `shift_addfast_cc`
  by (100.7−98.0) → `fir_decimate_cc` /32 (≈100 kHz cutoff) → `fmdemod_quadri_cf` →
  composite to `stereo_decode.py`.
- `stereo_decode.py`: 19 kHz pilot PLL → recover 38 kHz → demod L−R → matrix L/R → 75 µs
  de-emphasis per channel → resample to 48k stereo → stdout to ffmpeg → Icecast on a
  **test mount** (`/test.mp3`), **not** `/fm.mp3`.
- No Flask changes, no `channels.json` yet — single hardcoded channel via `mux.env`.

**Run it as an attended A/B:** `systemctl stop sdr-fm@active`; start capture + the single
pipeline; compare `/test.mp3` (new stereo) against a recording of `/fm.mp3` (legacy mono)
on 100.7. Restore `sdr-fm@active` immediately after.

**Acceptance gate (all must pass):**
- New stereo path on 100.7 sounds **≥ legacy mono** — clean stereo separation, no
  artifacts, no dropouts over a 10-minute listen.
- No ADC overload at the chosen gain with the full 6 MHz in-band.
- Capture daemon holds the device stably for ≥30 min with no buffer-drop spam.
- Rollback to `sdr-fm@active` is verified working.

**If the gate fails:** stop, leave `sdr-fm@active` running, report findings. Do not proceed
to Phase 2.

---

## Phase 2 — fan out to N channels + UI + RDS toggle

**Goal:** "more of the same," once the demod stage is trusted.

**Scope:**
- `iq_capture.py`: fanout to up to 4 subscribers (each gets full IQ; ~64 MB/s × N — fine on
  Pi 5 LPDDR, but if bandwidth/CPU bites, the documented optimization is a shared-memory
  mmap ring, deferred).
- `mux_supervisor.py`: read `channels.json`, launch/reap one `channel_pipeline.sh` per
  active channel (≤4 enforced), each on its own mount (`/m{freq}.mp3`, dot→underscore).
  Per-channel `stereo` and `rds` flags. Designate one channel `primary`: it gets RDS
  unconditionally, writes `now_playing.json` (legacy name) **and** also serves `/fm.mp3`
  so the existing UI/captions keep working. `SIGHUP` = reload channel set without dropping
  unchanged channels.
- `mono` channels skip `stereo_decode.py` (15k LPF + deemph + resample only).
- RDS: tee the composite to `redsea` per channel where `rds:true`; `rds_watcher.py` writes
  `now_playing-<mount>.json`.
- Flask (`app.py`): endpoints to list window stations (95.0–101.0, greying the rest),
  add/remove a channel (reject >4 with a clear error), toggle `stereo`/`rds` per channel;
  write `channels.json`; `SIGHUP` the mux. Per-mount `/api/now_playing?mount=`.
- UI: a multistation panel (which mounts are live, what each is playing, per-mount
  stereo/RDS toggles, a player per mount). Keep it server-rendered + vanilla JS polling,
  no build step.
- **Cutover decision (explicit, not automatic):** whether `sdr-mux` *replaces*
  `sdr-fm@active` as the default FM path, or stays opt-in, is a separate call after this
  ships. Default for now: mux is opt-in; legacy mono remains the boot default.

**Acceptance gate:**
- 4 channels stream simultaneously, each independently selectable, primary stereo+RDS,
  others per their flags.
- CPU under 4-channel load leaves clear headroom for radio + scanner stability (invariant 6).
- Switching the active channel set via the UI doesn't drop unaffected channels.
- AM tuning and wxsat capture still correctly stop the mux first (device coordination).

---

## Dependencies / bootstrap

Add to `bootstrap.sh` (idempotent):
- Build/install **csdr** from source (Trixie has no package). If the build fails, that's a
  hard stop per invariant 7.
- Python: `numpy` for `stereo_decode.py` (and `scipy` only if the resampler needs it; prefer
  a polyphase resampler that avoids the scipy dep if practical).
- SoapySDR Python bindings already present from the dx-R2 migration — verify, don't reinstall.

## Out of scope (do not build)

- Polyphase channelizer (only if >4 simultaneous is ever wanted).
- Per-channel captions / Whisper.
- Shared-memory IQ ring (documented optimization, deferred).
- AM multistation (window is FM-only).
- Auto-cutover of the boot-default FM path.

## Downstream touch-points to flag (don't fix here, just note in the PR)

- **wxsat skip-when-listening gate** reads Icecast listener count on `/fm.mp3` and
  `now_playing.json`. With multiple mounts live, that gate should eventually sum listeners
  across all mux mounts — note it, leave it.
- **NPMplus**: new mounts (`/m*.mp3`) need proxy entries if exposed via `icecast.rg2.io`.

## Working rules

- Complete file rewrites over diffs.
- Deploy via `sudo /srv/radio/deploy.sh`; commit only after live verification.
- Headless Pi: no `aplay` — test audio by listening to the Icecast mount in a browser.
- Pre-approve the new `systemctl` verbs in `.claude/settings.json`.
- tmux for the session.
