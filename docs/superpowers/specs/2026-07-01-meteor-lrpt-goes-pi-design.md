# Meteor LRPT on the GOES Pi — reviving the wxsat stack

**Date:** 2026-07-01
**Status:** Design — approved for planning
**Author:** brainstorming session (robertegardner + Claude)

## Problem

A tuned Meteor antenna (with an **externally powered LNA**) and a Nooelec NESDR
SMArt v5 RTL-SDR now live near the dedicated GOES decode Pi (`goes.srvr`,
192.168.6.134, Pi 5). The user wants to decode Meteor-M2 LRPT with that dongle on
that Pi.

When the Nooelec was plugged into `goes.srvr`, `lsusb` showed two identical
`0bda:2838 RTL2838` devices and the **GOES capture flaked**. The Nooelec is
currently unplugged; GOES is `active` and capturing.

### Root cause of the flake (confirmed)

`goes.service` runs (from `pi-goes/provision-goes.sh.tpl`):

```
satdump live goes_hrit … --source rtlsdr --frequency … --gain …
```

There is **no device selector**. With one RTL present that is fine. With two
identical RTL2832U dongles, SatDump binds to **enumeration index 0** — a coin
flip between the SMArTee XTR (GOES, serial `47360874`) and the Nooelec. When it
grabbed the wrong dongle (no GOES antenna / LNA path at 1694 MHz), GOES decoded
nothing. Not a hardware fault, not contention — a device-identity collision.

This is the same class of problem already solved on the p24 ADS-B Pi
(`pi-adsb`, select-by-serial) and in `pi-wxsat` (serial-pinned, hard-fail).

## Key insight: the whole pipeline already exists

The Meteor/wxsat pipeline is built and **registry-driven** — it is only DARK
because the Nooelec device (`nooelec-wx`) is shelved (`present: false`, retired
from p24 2026-06-19 as a flaky-dongle pause).

- **`pi-wxsat`** — serves the Nooelec over `rtl_tcp`, selecting it **strictly by
  unique serial with a hard-fail** (`wxsat-rtltcp.sh`: refuses to serve rather
  than ever fall back to device 0). This is the dongle-collision protection,
  already written and proven.
- **`radio-compute` wxsat stack** (rack, .84):
  - `wxsat_scheduler.py` — pyorbital pass prediction (via `wxsat_predict.py`),
    schedules captures, writes `captures.json` + `wxsat_passes.json` +
    `wxsat_status.json`, `DRY_RUN` gate.
  - `wxsat_record_rtltcp.py` + `wxsat_capture_rack.sh` — record CU8 from the
    remote `rtl_tcp`, decode offline with SatDump (`meteor_m2-x_lrpt`).
  - `wxsat_live.py` — the per-pass **waterfall/spectrograph + level + az/el
    pass-arc "track"**, written to `wxsat_live.json` for the gallery.
  - Served by the radio app's `/wxsat` gallery. **This is "the prior gallery"
    that captured overhead pass geometry + spectrograph.**

The scheduler is parameterized by `WXSAT_RTLTCP_HOST`, which flows from the
registry device's `host` field (`radio-compute/main.tf`:
`wxsat_rtltcp_host = try(local.wxsat_dev.host, "p24.srvr")`).

**Consequence:** moving Meteor from p24 to `goes.srvr` is mostly a registry edit
plus a live env edit, not new decode code. It also restores the platform's core
rule — *the Pi serves raw samples over the network; the rack does the DSP*. (GOES
HRIT is the geostationary exception that decodes on the Pi; Meteor LRPT follows
the normal rule and decodes on the rack.)

## Architecture

```
GOES Pi (goes.srvr / .134)                         radio-compute (.84, rack)
├─ goes.service → SMArTee (47360874) → GOES HRIT    (unchanged, now PINNED)
└─ wxsat-rtltcp → Nooelec v5 (serial X) :1234 ──rtl_tcp──▶ wxsat-scheduler
      (serial-pinned, hard-fail)          ~24 Mbps           ├─ predict passes (pyorbital)
                    ▲ ext-powered LNA      during passes      ├─ record CU8 + SatDump LRPT
                    │ upstream → RTL gain LOW               ├─ wxsat_live: waterfall + track
                                                             └─ /wxsat gallery + captures.json
                                                                      │
                                            ntfy push  ◀───── pass & decode hooks (NEW)
                                            home.rg2.io Meteor tile ◀─ status/captures JSON (NEW)
```

RTL-side gain stays **near-minimum** because the externally powered LNA is
upstream. The existing calibration is exactly for this: `WXSAT_GAIN_TENTHS=72`
(7.2 dB) gives clean IQ (0% clip, mean|IQ|≈40); 40 dB stacked on the LNA clipped
~19% and killed the LRPT decode (2026-06-18). Re-check clip% at 137.9 after
cutover; do not raise gain without that check.

## Components & changes

### 1. Safety fix — pin GOES to its dongle (`pi-goes`) — CRITICAL, independent

Add a serial→index pin so `goes.service` can never grab the Nooelec:

- A resolver (reusing pi-wxsat's `rtl_test 2>&1 | grep "SN: <serial>"` →
  index pattern) runs as `ExecStartPre`, resolves the SMArTee's index for serial
  `47360874`, **hard-fails if absent** (refuse to start rather than grab index
  0), and writes `GOES_SOURCE_ID=<idx>` to a runtime EnvironmentFile
  (e.g. `/run/goes/source.env`).
- `goes.service` gains `--source_id ${GOES_SOURCE_ID}` on its SatDump ExecStart.
  SatDump's device selector is `--source_id` (verified in the binary); for
  RTL-SDR it is the librtlsdr enumeration index.

Implementation constraint: `goes.service` is **keep-if-absent** (hand-tuned
freq/gain/samplerate must be preserved). The pin is inserted in-place, guarded by
a marker, **preserving** the existing tuned values — parse/keep freq, gain,
samplerate, output dir; only add `--source_id ${GOES_SOURCE_ID}` and the
`ExecStartPre` + `EnvironmentFile`. Idempotent on re-apply. After this fix, the
Nooelec can be hot-plugged with zero risk to GOES.

The GOES serial (`47360874`) becomes a documented value; make it a template var
(default `47360874`) so it is not a magic literal.

### 2. Serve the Nooelec over rtl_tcp on the GOES Pi (repoint `pi-wxsat`)

Repoint the existing `pi-wxsat` module from p24 to `goes.srvr` (decision A,
approved: repoint, do not fold into pi-goes). The module is generic — it selects
the dongle strictly by serial and hard-fails, so on `goes.srvr` it protects the
GOES SMArTee exactly as it protected p24's ADS-B dongles.

- `var.wxsat_host` → `goes.srvr` (in `terraform.tfvars` on thebeast).
- `var.wxsat_ssh_user` → the GOES Pi's user (`rgardner`) if it differs from p24.
- Comments in `provision-wxsat.sh.tpl` reference p24/ADS-B; refresh the wording to
  "GOES Pi / protect the GOES SMArTee" (logic unchanged).

Two modules (`pi-goes` + `pi-wxsat`) will remote-exec into the same host. They
touch disjoint units. Known interactions to handle:

- **modprobe blacklist filename collision:** both write
  `/etc/modprobe.d/blacklist-rtlsdr-dvb.conf` with (essentially identical)
  DVB-blacklist content but different `platform-managed (pi-goes|pi-wxsat)`
  marker comments. Harmless (same effect, last-writer-wins) but should be made
  explicitly idempotent/compatible so re-applies do not thrash.
- **usbfs cap:** `goes.srvr` currently has `usbfs_memory_mb=0` (unlimited).
  `pi-wxsat` sets a positive cap for multi-dongle hosts. Ensure the cap it
  imposes is generous enough for GOES (~2.5 Msps continuous) + Nooelec (~1.5
  Msps during passes) — a positive cap replaces "unlimited", so it must be large
  enough not to starve GOES.

### 3. Registry (`terraform/registry/devices.json`)

Un-shelve the wxsat device:

- `nooelec-wx`: `host: "goes.srvr"`, `endpoint: "tcp://goes.srvr:1234"`,
  `serial: "<new Nooelec's serial>"` (read on the Pi during implementation via
  `rtl_test -t`; the p24 unit was `22012952`, the new one may differ),
  `present: true`. Keep `domain: "wxsat"`, `role: "meteor-lrpt"`. Update the
  `_comment` to reflect the GOES-Pi home + externally powered LNA.

`wxsat_devices` (root `main.tf`) = present devices with `domain == "wxsat"`, so
flipping `present: true` re-enables both the `pi-wxsat` and `radio-compute` wxsat
blocks; `wxsat_rtltcp_host` then derives `goes.srvr` automatically **on a fresh
env write** (see gotcha below).

### 4. Un-gate the scheduler for the validation phase

Goal (user): "for the first couple days I want continuous decode to see what our
setup can pull in… after we're sure the RF chain works, we can tailor a pass
timer." The gallery is inherently per-pass, so the practical form of "continuous"
is **auto-capture every pass, unattended**:

- **Phase 1 (validation):** `DRY_RUN=0`, a **low `MIN_ELEV_DEG`** (e.g. 8–10 to
  catch marginal passes), and **both active Meteor sats enabled**
  (`M2_4_ENABLED=1`, `M2_3_ENABLED=1`). Location already set (`LAT=37.31`,
  `LON=-89.55` = Cape Girardeau). Keep `WXSAT_GAIN_TENTHS=72`.
- **Phase 2 (later):** raise `MIN_ELEV_DEG`, select best sat(s), refine windows —
  this is the "tailor a pass timer" step. No code change, just env.

**Gotcha:** `/etc/radio-compute/wxsat.env` is written **keep-if-absent**. If it
already exists on .84 (from the p24 era), changing the registry host will NOT
rewrite it. Cutover therefore edits the env **live on .84**
(`WXSAT_RTLTCP_HOST=goes.srvr`, `DRY_RUN=0`, sat enables, `MIN_ELEV_DEG`) and
restarts `wxsat-scheduler`, OR delete the env and re-apply to regenerate from the
registry. The `--force` one-shot capture path
(`wxsat_scheduler.py … --force`, bypasses schedule AND DRY_RUN) is the fast
end-to-end RF-chain test right after the Nooelec is serving.

### 5. Alerts (NEW — small additions)

**ntfy** (new; no existing ntfy wiring in the tree):
- Add `NTFY_URL` / `NTFY_TOPIC` env (keep-if-absent, like other secrets).
- Emit a push on **pass starting** (scheduler already knows AOS) and on
  **decode landed** (include sat name, max elevation, sync/quality metric).
- Best-effort, non-fatal (a failed ntfy POST never breaks a capture).

**Dashboard tile** (`modules/dashboard/dashboard.py`, `home.rg2.io`):
- Add a **Satellite / Meteor** tile listing **upcoming expected passes** (from
  `wxsat_passes.json` / `wxsat_status.json`) and **past results** (from
  `captures.json`, with the pass thumbnail).
- Reuse the dashboard's server-side aggregation pattern (background poll of the
  plain-HTTP backend, page reads one same-origin `/api/dashboard`); proxy the
  latest Meteor thumbnail the same way the GOES thumbnail is proxied
  (`/api/proxy/...`). New backend base env-tunable in
  `/etc/dashboard/dashboard.env` (keep-if-absent).

## Data flow

1. GOES Pi: `wxsat-rtltcp.service` serves the Nooelec (serial-pinned) on
   `:1234`. `goes.service` (pinned to the SMArTee) is untouched.
2. Rack `wxsat-scheduler` predicts passes → writes `wxsat_passes.json` /
   `wxsat_status.json`; on ntfy: "pass starting".
3. At AOS (−`AOS_BUFFER_S`) it records CU8 from `goes.srvr:1234` via `rtl_tcp`,
   `wxsat_live.py` writes live waterfall + track to `wxsat_live.json`.
4. At LOS it decodes with SatDump (`meteor_m2-x_lrpt`) → products land in
   `WXSAT_DIR`; `captures.json` updated; ntfy: "decode landed".
5. `/wxsat` gallery serves passes + geometry + spectrograph; dashboard tile
   surfaces upcoming + past.

## Error handling & safety

- **GOES protected two ways:** (a) `goes.service` pinned to serial `47360874`,
  hard-fail if absent; (b) `wxsat-rtltcp` serves only the Nooelec's serial,
  hard-fail rather than grab device 0. Neither can steal the other's dongle.
- **rtl_tcp / capture failures** are already handled by the existing stack
  (soft-fail, retry, keep-IQ-on-fail). ntfy is best-effort.
- **Gain overload** is the known Meteor failure mode with an upstream LNA — keep
  RTL gain at 7.2 dB; validate clip% before raising.
- **Re-apply safety:** all provisioner writes stay keep-if-absent / marker-guarded
  per platform rules; the GOES pin edit is idempotent (marker-guarded, preserves
  tuned values).

## Out of scope (YAGNI / deferred)

- The Phase 2 pass timer refinement (thresholds/sat selection) — env-only, later.
- NOAA APT on the same antenna/dongle — 137 MHz band works, but not requested.
- Pulling Meteor products to the `goes-archive` LXC / a second gallery — the
  existing `/wxsat` gallery on radio-compute is the surface.
- Replacing the flaky-history Nooelec with the on-order RTL v4 — if the new
  dongle proves flaky like the p24 unit, that swap is a registry serial change.

## Deploy notes

- Two cadences (CLAUDE.md): infra/units/registry → `terraform apply` (taint the
  relevant `null_resource`); the keep-if-absent env cutover is a **live edit on
  .84** + `systemctl restart wxsat-scheduler`.
- `terraform` runs on thebeast as `deploy`; edit `terraform.tfvars` there for
  `var.wxsat_host`. Never `rsync --delete` the terraform tree (state is
  thebeast-only). Validate with `terraform validate`; never `terraform fmt`.
- Targeted applies: `module.pi_wxsat` (serve Nooelec on goes.srvr),
  `module.pi_goes` (GOES pin), `module.radio_compute` (scheduler follows host),
  `module.dashboard` (Meteor tile).

## Open items to resolve during implementation

- Read the new Nooelec's actual serial on `goes.srvr` (`rtl_test -t`) for the
  registry.
- Confirm `var.wxsat_ssh_user` for `goes.srvr`.
- Confirm the exact `pi-wxsat` usbfs cap value vs GOES's needs.
- Confirm both Meteor-M2 sats' current LRPT frequencies for the sat-enable flags.
