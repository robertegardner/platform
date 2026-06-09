# SDR Platform — V2 Architecture

Top-of-stack architecture for the homelab SDR system. `PROJECT_MEMORY.md`
should point here as the authoritative design reference. New `platform` repo
is v1; `radio` and `scanner` move to v2 (compute-only, rack-side).

## What changed and why

The Pi 5 thermally throttled running MOSWIN P25 + >2 FM channels. The fix is to
**relocate DSP to the rack, not reduce it.** The Pi becomes a pure
sample-acquisition node; all compute (FM mux/stereo, op25, SatDump) and
distribution (Icecast) move rack-side. In parallel, the failing Nooelec is
replaced by a 4-tuner set, which gives every radio job its own dedicated tuner.

That second change cascades into large simplifications. Surfacing them so we
don't carry dead complexity:

- **RF switch / GPIO relay — dead.** Antenna selection is device selection.
- **wxsat skip-when-listening gate — obsolete.** Meteor now has a dedicated
  tuner (RTL v4); a capture no longer interrupts FM/AM listening, so there's
  nothing to skip around.
- **Scanner scheduler's satellite/NOAA job — removed.** Weather sat is
  radio-domain on the RTL v4; the scanner scheduler drops to terrestrial jobs only.
- **dx-R2 multi-antenna-port use — moot.** dx-R2 is FM-only now; Antenna B/C
  are spare. (The 3-port feature that first justified the dx-R2 is no longer
  load-bearing — the device is still the right FM tuner.)
- **rtl_tcp as the scanner transport — gone.** Everything is SoapyRemote
  (rtl_tcp survives only as a possible fallback for the Meteor→SatDump leg).
- **Pi-local Icecast fallback — dropped.** Rack-down ≈ network-down, so a
  Pi-local serving path protects nothing reachable.
- **Intra-radio-domain arbitration — dissolved.** FM/AM/Meteor are three
  separate tuners; they just run.

## The three tiers

```
  ACQUISITION (Pi 5, attic)        DISTRIBUTION (rack)         COMPUTE (rack)
  ─────────────────────────        ───────────────────         ──────────────
  4 tuners on PoE-powered hub      Icecast (all mounts)        radio v2  (LXC)
  1 source server per device       NPMplus reverse proxy        - FM mux/stereo
  device registry (config)         mount registry (config)      - AM
  platform agent (brings up                                     - Meteor/wxsat (SatDump)
   servers per registry,                                       scanner v2 (LXC)
   sets bias-tee)                                               - op25 scheduler
        │ samples out (~400 Mbps)                               - AIS / ACARS / ATC
        └──────────── GbE ───────────► rack ◄── clients connect via driver=remote
```

Each device is owned by exactly **one** compute domain. No device is shared
across domains → no cross-domain arbiter is needed.

---

## Tier 1 — Acquisition (Pi)

The Pi runs no DSP. Per device it runs one isolated **source server** that
exposes raw samples on the network, plus a thin **platform agent** that brings
those servers up from the device registry and sets device-level state (bias-tee,
antenna documentation, sample-rate ceiling).

### Device registry (`platform`-owned config)

The artifact that replaces the RF switch. Source of truth for what's plugged in,
where it's served, and who owns it.

```json
{
  "devices": {
    "dx-r2": {
      "soapy_args": "driver=sdrplay,serial=<SERIAL>",
      "antenna": "Antenna A",
      "feed": "Shakespeare 5120",
      "filter": "FM bandpass",
      "role": "fm-multistation",
      "domain": "radio",
      "transport": "soapy-remote",
      "endpoint": "tcp://pi-attic:55001",
      "sample_rate_max": 8000000,
      "bias_tee": false,
      "usb_controller": "A"
    },
    "hf-plus": {
      "soapy_args": "driver=airspyhf,serial=<SERIAL>",
      "antenna": "single",
      "feed": "YouLoop (primary) / long-wire (alt)",
      "filter": "HF choke on long-wire",
      "role": "am-broadcast",
      "domain": "radio",
      "transport": "soapy-remote",
      "endpoint": "tcp://pi-attic:55002",
      "bias_tee": false,
      "usb_controller": "A"
    },
    "airspy-r2": {
      "soapy_args": "driver=airspy,serial=<SERIAL>",
      "antenna": "single",
      "feed": "discone",
      "filter": "Flamingo FM band-stop",
      "role": "scanner-terrestrial",
      "domain": "scanner",
      "transport": "soapy-remote",
      "endpoint": "tcp://pi-attic:55003",
      "sample_rate_default": 2500000,
      "bias_tee": false,
      "usb_controller": "B"
    },
    "rtl-v4": {
      "soapy_args": "driver=rtlsdr,serial=<SERIAL>",
      "antenna": "single",
      "feed": "V-dipole",
      "filter": "Sawbird+ NOAA (LNA)",
      "role": "meteor-lrpt",
      "domain": "radio",
      "transport": "soapy-remote",
      "endpoint": "tcp://pi-attic:55004",
      "bias_tee": true,
      "usb_controller": "B"
    }
  }
}
```

### Source servers

- Prefer **one server per device** (fault isolation + clean single-client
  semantics), each on its own port per the registry `endpoint`. Mechanism is a
  bring-up detail (separate `SoapySDRServer` instances pinned by serial, or one
  server with per-device addressing — prefer the former for isolation).
- Transport is **SoapyRemote** for all four. The **Meteor→SatDump** leg is the
  one allowed exception: prefer SoapyRemote, fall back to **rtl_tcp** if
  SatDump's remote-Soapy source proves unreliable. This is a bring-up decision.
- **Wire format:** CS16 for dx-R2/Airspys (lossless for 14/12-bit, halves
  bandwidth vs CF32); CU8 for the RTL v4 (8-bit native).

### Platform agent

Reads the registry, launches one server per present device, and owns
**device-level state that isn't a client concern** — most importantly the
**RTL v4 bias-tee ON** (powers the Sawbird) before serving Meteor. Re-launches a
crashed server without touching the others.

### Power & USB (see `ACQUISITION_TIER.md`)

PoE+ splitter (fixed 5V/4A) → self-powered USB hub, on a second PoE drop,
decoupled from the Pi's PoE budget. Hold dx-R2 ≤8 Msps and run R2 narrowband so
a single hub stays under one USB controller's ~480 Mbps; split to two hubs
across both controllers for headroom.

---

## Tier 2 — Distribution (rack)

- **Icecast** hosts all audio mounts. Co-located with compute on the rack, so
  audio never traverses the Pi link — only outbound samples do.
- **NPMplus** proxies the public hostnames (`icecast.rg2.io`, `radio.rg2.io`,
  `scanner.rg2.io`) to the rack Icecast and the two compute UIs.

### Mount registry (`platform`-owned config)

Defines the audio namespace and domain ownership so NPMplus routing and the UIs
agree. Audio only — non-audio artifacts are served by their compute UI.

| Mount | Domain | Source |
|---|---|---|
| `/fm.mp3` | radio | primary FM channel (back-compat URL) |
| `/fm-<freq>.mp3` | radio | additional FM channels (≤4 total) |
| `/am-<freq>.mp3` | radio | AM broadcast (e.g. `/am-1120.mp3` KMOX) |
| `/scanner-p25.mp3` | scanner | active P25 talkgroup audio |
| `/scanner-atc.mp3` | scanner | ATC audio (when R2 is on ATC) |

Non-audio: Meteor PNGs (radio `/wxsat` gallery), AIS/ACARS logs (scanner UI).
`now_playing-<mount>.json` written rack-side, per mount.

---

## Tier 3 — Compute (rack)

Two LXCs preserve the domain-separation discipline (no cross-contamination).

- **radio v2:** FM mux + stereo (the 6 MHz @ 98, ≤4-channel, RDS-on-primary
  build), AM, and Meteor/wxsat (SatDump). Owns dx-R2, HF+, RTL v4. Serves
  `radio.rg2.io` and the `/wxsat` gallery.
- **scanner v2:** op25 scheduler (P25 default) + AIS + ACARS + ATC. Owns the
  Airspy R2. Serves `scanner.rg2.io`.

Internals are **unchanged** from v1 — only the bottom edge (samples now arrive
from a remote source instead of a local device open) and the deploy target (rack
instead of Pi). This is a major version bump per repo, not a rewrite. No GPU
needed; the Whisper caption host stays where it is.

---

## The contracts

### Source contract (platform → compute)

1. Each device is published at a stable endpoint from the registry.
2. **Single client per device.** The server enforces one connection.
3. The platform guarantees device readiness (powered, plugged to the documented
   antenna, bias-tee set) before serving. It does **no DSP**.
4. Compute consumers set freq/rate/antenna/gain via the SDR API at connect,
   within registry ceilings (e.g. dx-R2 ≤8 Msps; R2 default 2.5 Msps).
5. A compute repo connects **only to devices whose `domain` it owns.**

### Mount contract (compute → distribution)

1. All audio is published to the rack Icecast as a source client, named per the
   mount registry.
2. The primary FM channel uses `/fm.mp3` to preserve existing UI/URLs.
3. Non-audio outputs are **not** Icecast mounts — they are files served by the
   owning compute UI.
4. Listeners pull from NPMplus → rack Icecast. They never touch the Pi.

---

## Arbitration (rack-side)

No global/cross-domain arbiter exists or is needed — devices aren't shared
across domains. Arbitration is per-domain:

- **Radio domain:** dx-R2 (FM), HF+ (AM), RTL v4 (Meteor) are three independent
  devices. No time-slicing. All run concurrently. Nothing to arbitrate.
- **Scanner domain:** the Airspy R2 is one device multiplexed across P25 / AIS /
  ACARS / ATC. The **scanner scheduler holds one persistent R2 client and
  retunes per job** (it does not open/close the source repeatedly). Priority:
  manual override > scheduled poll (AIS/ACARS) > P25 default. The old
  satellite-preemption priority is gone (Meteor left the domain).

Device-level enablement (bias-tee, server lifecycle) is the **platform agent's**
job, not the compute client's.

---

## Network & failure model

- **Pi link:** ~400 Mbps outbound samples (dx-R2 ~256 + R2 ~80 + HF+ ~24 + RTL
  ~24–48) on GbE — ~40%, comfortable. Audio is rack-internal; listener fanout
  never touches the Pi.
- **Latency:** non-issue. Everything is buffered through Icecast.
- **Failure isolation:** per-device servers fail independently; the two compute
  LXCs fail independently. Rack-down = no streaming, accepted (≈ network-down).
  Pi-down = no samples, hard stop (no fallback by design).

---

## Migration

Per-repo, gated, in the order that minimizes risk:

1. **platform repo (new):** device registry, per-device source servers + agent
   on the Pi; Icecast + mount registry + NPMplus routing on the rack. `deploy.sh`
   takes a target (`pi` | `rack`). Bring up servers, verify each device streams
   to a rack client raw (no DSP yet).
2. **scanner v2 first** (lower blast radius than the radio's live listeners):
   repoint op25 from local device to `driver=remote` against the R2 endpoint;
   verify P25 lock and the scheduler retune-in-place. Confirm the throttle is
   gone with op25 rack-side.
3. **radio v2:** repoint the FM mux / AM / SatDump to their remote endpoints;
   cut Icecast over to the rack; repoint `icecast.rg2.io` in NPMplus. The
   mux/stereo build itself proceeds per `MULTISTATION_STEREO_BUILD.md`, now
   consuming a remote source.

Each repo keeps test-on-live discipline; no monolith bring-up.

## Repos

| Repo | Version | Deploys to | Owns |
|---|---|---|---|
| `platform` (new) | v1 | Pi (servers/agent) + rack (Icecast/NPMplus/registries) | acquisition + distribution |
| `radio` | v2 | rack (LXC) | FM mux/stereo, AM, Meteor/wxsat compute |
| `scanner` | v2 | rack (LXC) | op25 scheduler, AIS, ACARS, ATC compute |

## Open bring-up decisions

- **Meteor transport:** SoapyRemote vs rtl_tcp for SatDump (default: try Soapy).
- **op25 over SoapyRemote:** verify gr-osmosdr `soapy=` consumes the R2 endpoint
  cleanly; rtl_tcp is not available as a fallback here (R2 isn't RTL).
- **Source server isolation mechanism:** per-device `SoapySDRServer` instances
  vs single multi-device server (default: per-device).
- **Compute hosting:** two LXCs (recommended) vs one with separate users.
