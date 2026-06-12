# session_notes.md — SDR Platform V2 build log

Working notes per session, newest first. Full detail lives in
`deployment_notes.md` (results, runbooks) and git history; this is the quick
"where were we" index.

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
