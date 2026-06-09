uisition Tier — Locked Hardware Architecture

Authoritative hardware doc for the V2 split (Pi acquires, rack computes).
Supersedes the hardware sections of `RF_CHAIN_ADDENDUM.md`. Merge into
`PROJECT_MEMORY.md` and commit.

## Decision: 4-tuner acquisition (LOCKED)

The Pi is a pure sample-acquisition node. Four tuners, each on a dedicated
antenna with a dedicated inline filter/LNA. Antenna selection is device
selection — no RF switch, no GPIO relay. All DSP (FM mux/stereo, op25, SatDump)
runs on the rack against `driver=remote` / network sources.

Max simultaneity: **FM-multi + AM + one scanner job + Meteor, all concurrent.**

## Tuner → antenna → filter → job

| Tuner | Driver | Antenna | Inline filter / LNA | Job | Cadence |
|---|---|---|---|---|---|
| SDRplay dx-R2 | sdrplay | Shakespeare 5120 | FM bandpass | FM multistation 95–101 | continuous |
| Airspy HF+ (Discovery) | airspyhf | YouLoop (primary) / long-wire (alt) | HF choke on long-wire | AM broadcast (KMOX, KZYM) | continuous |
| Airspy R2 | airspy | discone | Flamingo FM band-stop | P25 769 / AIS 162 / ACARS 131 / ATC 118–137 | scheduler time-slices |
| RTL-SDR Blog v4 | rtlsdr | V-dipole | Sawbird+ NOAA (LNA) | Meteor LRPT 137.9 | scheduled passes |

Meteor lives on the dedicated RTL v4 (its own bias-tee powers the Sawbird),
which keeps the dx-R2 pure-FM with zero contention. HF+ version: **Discovery**
(single port is sufficient — Meteor is not on the HF+; the Discovery's
preselectors are a small plus for AM in a strong-signal environment).

## Power subsystem (no line power in the attic)

SDR power is **decoupled from the Pi's PoE budget**: a second PoE drop feeds a
PoE+ splitter → self-powered USB hub → the four SDRs. The Pi keeps its own PoE
HAT for the Pi + fan only.

- **Splitter:** PoE+ (**802.3at**, NOT af), **fixed 5V / 4A / 20W**. Must NOT be
  a PD/QC unit (avoid voltage negotiation). Candidates: UCTRONICS PoE+ splitter
  barrel-or-USB-C (B087FBNCN6); DSLRKIT 5V/4A (Pi-5 tested); REVODATA / GeeekPi /
  52Pi equivalents. Match the splitter output connector to the hub's power input.
- **Hub:** self-powered (powers downstream from its own input, no VBUS backfeed
  to the Pi — verify per unit). USB 2.0 is electrically sufficient (all four SDRs
  are USB 2.0); per-port power switches recommended for power-cycling a wedged SDR.
- **Second drop:** needs a spare PoE port + a second Ethernet run to the attic.
  The splitter's RJ45 data passthrough can serve as a spare network drop.

### Power budget

| Load | Approx draw | Source |
|---|---|---|
| Pi 5 (under load) + HAT fan | ~12–14 W | Pi's existing PoE HAT (unchanged) |
| dx-R2 | ~1.5 W | PoE+ splitter → hub |
| Airspy R2 | ~2.5 W | " |
| Airspy HF+ | ~1 W | " |
| RTL-SDR v4 | ~1.5 W | " |
| Sawbird+ NOAA LNA | ~0.5 W (via RTL v4 bias-tee) | " |
| **SDR subtotal** | **~7 W** | 20 W splitter — large headroom |

## USB layout (Pi 5)

Two independent xHCI controllers, one per diagonal USB-3/USB-2 pair.

- **One hub (default):** all four SDRs share one controller's ~480 Mbps USB-2
  budget: dx-R2 @8 Msps (~256) + R2 narrowband P25 (~80) + HF+ (~24) + RTL Meteor
  (~48) ≈ **408 Mbps**. Fits, but only if **dx-R2 stays ≤8 Msps**.
- **Two hubs (headroom / future 10 Msps):** split across the two USB-3 ports
  (two controllers); both hubs fed from the one 4A splitter. Put dx-R2 on its own
  controller.

## Verify / caveats

- **Splitter is 802.3at fixed-5V**, not af (12.5W) and not PD/QC.
- **Hub does not backfeed** the Pi; per-port switches preferred.
- **Hold dx-R2 ≤8 Msps** on a single hub, or split to two hubs.
- **Run R2 narrowband** for P25 to keep its USB footprint small.
- **Sawbird power** comes from the RTL v4's bias-tee — confirm enabled in the
  rtlsdr driver. Do NOT put the Sawbird on the HF+ (no bias-tee).
- **Filter placement:** FM bandpass on FM only; FM band-stop on the scanner only;
  never stack the band-stop on the Meteor path (Sawbird SAW already rejects FM);
  HF chokes on the HF/AM path only.
- **YouLoop vs long-wire** for AM: decide by noise-floor measurement on KMOX, not
  assumption — the balanced loop usually wins in a noisy attic.

## Acquisition-tier consequence

The table above is the device ↔ antenna ↔ filter ↔ band registry that replaces
the dead RF-switch idea. In the `platform` repo it's a config lookup, not hardware.
