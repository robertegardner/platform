ent-notes.md — SDR Platform V2

Terraform-deployed Proxmox stack, modeled on `homelab-monitor`. Same deploy
mechanics: Terraform runs **on thebeast (192.168.6.163) as the `deploy` user**,
`terraform.tfvars` lives only on thebeast (gitignored, never committed),
provisioning is `null_resource` + `remote-exec` over SSH into each target.

## Where things happen (three locations, kept distinct)

- **Edited:** on the code-server VM (Claude Code over SSH in tmux). All app
  repos check out here. The `terraform/` tree is edited here too, but applied
  on thebeast.
- **Applied:** `terraform apply` runs on thebeast as `deploy`. Validate with
  `terraform validate`. **Never `terraform fmt -recursive`** (leaks tfvars). No
  `pct exec`, no root SSH to thebeast — Proxmox API token or SSH into the target.
- **Runs:** acquisition on the Pi (bare metal); compute + distribution in
  Proxmox LXCs.

## Repo layout (`platform`)

```
terraform/
  main.tf                         # root: provider + wires the four modules
  modules/
    pi-acquisition/               # NO container resource — null_resource only
      main.tf
      provision-pi.sh.tpl         # source servers + agent + device registry
      variables.tf
    radio-compute/
      main.tf                     # container + null_resource provision
      provision-radio.sh.tpl
      variables.tf
    scanner-compute/
      main.tf
      provision-scanner.sh.tpl
      variables.tf
    distribution/
      main.tf
      provision-icecast.sh.tpl
      variables.tf
docs/
  PROJECT-CONTEXT.md              # → points at PLATFORM_V2_ARCHITECTURE.md
  deployment-notes.md             # this file
proxmox-setup/                    # reuse homelab-monitor's deploy-user setup
```

The container resource + Proxmox provider come straight from homelab-monitor's
existing modules — Claude Code copies that pattern from `module.monitoring`
rather than re-deriving it.

## Targets

| Module | Proxmox resource? | vCPU | RAM | Disk | Privilege | VLAN |
|---|---|---|---|---|---|---|
| pi-acquisition | **no** (bare-metal SSH) | — | — | — | — | attic (see network-map) |
| radio-compute | container | 4 | 4 GB | 32 GB | **unprivileged** | Server (vlan_id=0) |
| scanner-compute | container | 2 | 2 GB | 16 GB | **unprivileged** | Server (vlan_id=0) |
| distribution | container (or merge w/ NPMplus host) | 1 | 1 GB | 8 GB | unprivileged | Server (vlan_id=0) |

VLAN placement defers to `docs/network-map.md`. Per homelab-monitor's rule:
Server/Backhaul are **untagged native → vlan_id = 0**; **never vlan_id = 1**
(`vmbr0` carries `bridge-vids 2-4094`). Compute LXCs must route to the Pi's
attic VLAN (sample sources) and to the distribution host. **No USB passthrough,
no device nodes** — samples arrive over the network, so plain unprivileged
containers suffice.

## What each provisioner installs (idempotent — re-run safe)

- **provision-pi.sh.tpl:** SoapyRemote *server*; vendor drivers
  (sdrplay API, SoapyAirspy, SoapyAirspyHF, SoapyRTLSDR) **install-if-absent**
  (SoapySDR + SoapySDRPlay3 are already built from source — do NOT rebuild); the
  platform agent + device registry + per-device `sdr-source@.service` units.
  Sets the RTL v4 bias-tee enablement here, Pi-side.
- **provision-radio.sh.tpl:** SoapySDR core + SoapyRemote *client* only (NOT
  vendor drivers — those live on the Pi); csdr (**build-if-absent**), ffmpeg,
  Python deps; clones the radio repo at a pinned ref; lays down the mux/AM/SatDump
  units. SatDump **build-if-absent**.
- **provision-scanner.sh.tpl:** SoapyRemote client; op25 boatbod
  (**build-if-absent** — slow); gr-osmosdr with the **soapy** plugin (verify it's
  present, it's how `driver=remote` is consumed); acarsdec / AIS deps; clones the
  scanner repo; lays down scheduler + UI units.
- **provision-icecast.sh.tpl:** Icecast; writes `icecast.xml` **only if absent**
  (don't clobber manual/UI changes); source password from tfvars via
  `templatefile()`.

After writing service configs: **`systemctl enable` + `systemctl restart`** —
never `enable --now` (won't restart an already-running unit, leaves new config
unloaded).

## Two deploy cadences

Terraform owns the slow/structural layer; the repos' own `deploy.sh` owns fast
app iteration — they don't fight:

- **Infra / deps / units / container specs** → `terraform taint
  'module.radio_compute.null_resource.provision' && terraform apply` (on
  thebeast). Re-provisions one target without disturbing the others.
- **App code iteration** → SSH into the LXC, `git pull` + the repo's existing
  `deploy.sh` (rsync + restart). No full `terraform apply` per code change —
  preserves the live-test loop. The container already has the checkout from
  provisioning.

## Module dependencies (deliberately loose)

Compute modules do **NOT** `depends_on` pi-acquisition or distribution — mirrors
`module.monitoring` not depending on `module.probes`. A down source or down
Icecast is a runtime concern the app layer tolerates; hard ordering would let one
failed target block `-target` re-provisions of the others.

## Secrets

- Icecast source password, any API tokens → `terraform.tfvars` on thebeast only,
  gitignored. Rendered into configs via `templatefile()` (`${var}` substitution).
- Use `$${VAR}` in `.sh.tpl` for literal shell braces; heredocs `<< 'EOF'`
  (quoted) so the shell doesn't expand `$` while `templatefile()` still
  substitutes `${var}`.

## SDR-specific gotchas (parallel to homelab-monitor's list)

- **Vendor drivers belong on the Pi only.** The compute LXCs need just SoapySDR
  core + SoapyRemote client. Installing sdrplay/airspy drivers in a container is
  wasted and confusing.
- **op25 / SatDump / csdr are source builds** — guard every one with
  build-if-absent or a re-apply rebuilds them (minutes each).
- **The Pi module has no container resource.** `null_resource` + `remote-exec`
  to the Pi's IP; everything install-if-absent because it's a live, pre-built host.
- **gr-osmosdr must carry the soapy plugin** in scanner-compute — it's the only
  path to the remote R2 (no rtl_tcp fallback; the R2 isn't RTL).
- **Bias-tee is Pi-side**, set by the platform agent, not the SatDump client.
- **Wire format:** CS16 for dx-R2/Airspys, CU8 for the RTL v4 — set client-side
  at connect, documented in the device registry.

## Bring-up order

1. `pi-acquisition` — bring up source servers; verify each device streams raw to
   a client on the Server VLAN (no DSP yet).
2. `distribution` — Icecast + NPMplus routing; repoint `icecast.rg2.io`.
3. `scanner-compute` — lower blast radius; repoint op25 to `driver=remote`,
   confirm P25 lock and that the throttle is gone with op25 rack-side.
4. `radio-compute` — mux/stereo/AM/SatDump against remote sources, per
   `MULTISTATION_STEREO_BUILD.md`.

## Distribution tier bring-up (2026-06-10): rack Icecast LIVE, no cutover

`module.distribution` applied: LXC **900** (`distribution`, 192.168.6.82, 1
vCPU/1 GB/8 GB, unprivileged, vlan_id=0, ubuntu-24.04) running Icecast 2.4.4
with the platform-managed `icecast.xml` (hostname `icecast.rg2.io`, port 8000,
same source password as the Pi's Icecast — by design, so source cutovers change
only the host). Mount namespace defined in `terraform/registry/mounts.json`.

**Verified end-to-end:** test source (ffmpeg, from the Pi — the exact future
cutover path) published `/test.mp3` at 128k; mount appeared in status-json;
listener pulled 256 KB of valid MP3; mount cleaned up on source disconnect.
Re-provision idempotent (`taint` + `apply`: icecast.xml mtime byte-identical —
marker guard works; service stays active). Production untouched throughout: all
five Pi mounts live, `icecast.rg2.io/fm.mp3` → 200 via the Pi.

**Deliberately NOT done (stand-up only):** NPMplus still proxies
`icecast.rg2.io` → Pi:8000; no Pi source client was repointed; the scanner was
not touched.

Gotchas surfaced:
- The deploy API token lacks `Pool.Allocate` → no Proxmox pool resource;
  platform LXCs are identified by the `platform` tag instead.
- The container root key comes from `ssh_public_key` (homelab-monitor's RSA
  key, `rgardner@penguin`) → `ssh_private_key_path` in tfvars must be
  `~/.ssh/id_rsa_homelab`, not `id_ed25519` (the Pi accepts both, the LXC only
  the injected one).
- Modules using bpg resources need their own `required_providers` block
  (non-hashicorp source isn't inherited by name).

### Future cutover runbook (NOT executed — per-domain, at each compute phase)

1. **scanner-compute phase:** point SDRTrunk's `icecastHTTPConfiguration`
   (playlist XML via `gen_aliases.py`) and scanner-transcribe's publish/read
   URLs from `localhost:8000` → `192.168.6.82:8000` (same credentials). Verify
   `/ems*.mp3` + `/monitor.mp3` sourced on the rack.
2. **radio-compute phase:** same for the FM publisher (`stream.sh` /
   `/etc/sdr-streams/*.env`) → `/fm.mp3` on the rack.
3. **When all mounts are rack-side:** in NPMplus (192.168.6.49, admin :81)
   change the `icecast.rg2.io` proxy host target Pi:8000 → 192.168.6.82:8000.
   Verify every mount through the public name, then disable the Pi's `icecast2`
   (`systemctl disable --now icecast2` on the Pi — only after listeners confirm).
4. Rollback at any step = revert the one changed publish URL / proxy target.

## Phase 0B transport proof — FINAL RESULT (2026-06-10, tuning window): **GO**

The 8 Msps stall below was **root-caused and fixed in a second attended window**:
kernel socket buffers. SoapyRemote requests ~100 MB socket buffers and installs
`/usr/local/lib/sysctl.d/10-SoapySDRServer.conf` saying so — but a sysctl drop
landing post-boot is never applied, so the Pi sat at the 4 MB default
(`net.core.wmem_max`), the server's UDP send path starved, and the sdrplay
stream died after ~6 s at 8 Msps.

**Tuning-window evidence (radio stopped, dead-man armed, restored + verified):**
- **Test A — local USB sanity:** `SoapySDRUtil --rate=8e6` on the Pi sustained
  ~7.9 Msps clean for 30 s. USB was never the problem (co-resident RTL2838 is a
  non-factor).
- **Fix:** `net.core.{rmem,wmem}_max=104857600` applied on the Pi and codeserver,
  persisted via `/etc/sysctl.d/`; source server restarted to pick them up. Now
  encoded in `provision-pi.sh.tpl` (writes `/etc/sysctl.d/10-sdr-source.conf` +
  `sysctl -p`).
- **Test B — the gate test: 120 s remote 8 Msps CS16** (fc=98.0, Antenna A, UDP
  default transport): sustained ~7.9 Msps instantaneous (7.82 Msps mean incl.
  slow-start, ~250 Mbps on the wire), **0 overflows, 0 timeouts, 0 errors**. The
  previously-stalling configuration now runs clean with NO SoapyRemote stream-arg
  tuning needed (default mtu/window/prot all fine).
- **Test C — signal at the V2 operating point:** 8 Msps capture at fc=98.0 shows
  station structure across the span (98.5 MHz at +8.4 dB). Caveat for
  radio-compute: the **default gain saturates the ADC** (`mean|IQ|≈0.98`) — the
  compute client must set sane gain at connect (per source contract #4), e.g. the
  2.5 Msps run at gain-default measured `mean|IQ|=0.375` with a 13.7 dB carrier.

**Gate 0B: GO.** Remote probe clean; stable multi-minute 8 Msps CS16 with zero
drops; remote freq/rate/antenna control proven; real signal confirmed. Safe to
proceed to `distribution` → `scanner-compute` → `radio-compute` when hardware
lands.

---

### Initial attempt (2026-06-09, superseded): NO-GO at 8 Msps

Proved SoapyRemote IQ from the **live dx-R2** (RSPdx-R2, serial 22012952) to a
rack client (codeserver, 192.168.6.218) over GbE. Source server
`sdr-source@dx-r2` on `radio.srvr:55001`; client connects with
`driver=remote,remote=radio.srvr:55001,remote:driver=sdrplay`. Live radio
(`sdr-fm@active`) stopped for the window and **restored + verified afterward**
(`/fm.mp3` back on Icecast, `radio.rg2.io`/`icecast.rg2.io/fm.mp3` → 200 audio).

**What works (transport is fundamentally sound):**
- Remote probe clean: RSPdx-R2 enumerated with antennas A/B/C, gain ranges,
  rates to 10.66 MSps. Remote freq/rate/antenna control all apply.
- **2.5 Msps CS16, fc=100.7 MHz, Antenna A, 25 s:** sustained ~2.46 Msps (98% of
  requested), **no stall**, server sdrplay stream threads healthy throughout.
- Captured IQ is **real signal**, not noise: FM carrier at 100.7 (KGMO) measured
  **13.7 dB** above the ±1 MHz noise floor; `mean|IQ| = 0.375`. (Full audio demod
  skipped — scipy absent on codeserver — spectral proof substituted.)

**What fails (the gate bar is not met):**
- **8 Msps CS16, fc=98.0 MHz, 90 s requested:** ran ~7.6–7.9 Msps for ~6 s, then
  the stream **stalled completely** — `readStream` returned `SOAPY_SDR_TIMEOUT`
  (-1) for the rest of the run, 0 further samples. This is the "latency stall /
  throughput problem" NO-GO condition. The gate requires a stable multi-minute
  8 Msps CS16 capture; not achieved.

**Verdict:** **NO-GO at 8 Msps.** Do NOT build distribution/compute on this until
8 Msps is stable. The transport, device control, and signal integrity are proven
at 2.5 Msps, so this is a throughput-tuning problem, not a dead end.

**Next (focused, in a fresh attended window):** investigate per the build prompt
before re-attempting 8 Msps —
- Receiver socket buffers on the client: raise `net.core.rmem_max`/`rmem_default`
  (SoapyRemote's stream is UDP datagrams; small kernel UDP buffers drop bursts).
- SoapyRemote stream args: `remote:mtu=` (default 1500 → try larger / jumbo if
  the switch path supports it), `remote:window=` (socket window), and try
  `remote:prot=tcp` vs the default to see which survives 8 Msps.
- Confirm the dx-R2 sustains 8 Msps **locally** on the Pi (rule out USB
  contention with the co-resident RTL2838 before blaming the network).
- Sweep intermediate rates (4 / 5 / 6 Msps) to find where the stall onsets.

**Bug fixed in the proof tooling:** `tools/capture-iq.py` originally OR-counted
`flags & SOAPY_SDR_OVERFLOW`, misusing the -4 *return code* as a flag bitmask;
that inflated overflow counts into the 100k+ range and was meaningless. It now
counts only genuine `ret == SOAPY_SDR_OVERFLOW` (-4) and reports
`SOAPY_SDR_TIMEOUT` (-1) separately as the stall signal.

### Provisioning gotchas surfaced this phase (Pi / radio.srvr)
- **`SoapySDRServer` is not in Debian's `soapysdr-module-remote`** — the apt path
  yielded no server binary, so the provisioner source-builds SoapyRemote to
  `/usr/local/bin`. The unit's `ExecStart` is patched to the detected path
  (apt `/usr/bin` vs source `/usr/local/bin`), not hardcoded.
- **`libsdrplay_api.so.3` is mode 0750 root:radio.** Only root (and the `radio`
  group) can read it. The source server runs as root, so it loads fine; any
  ad-hoc `SoapySDRUtil --find` as `rgardner` fails to dlopen the SDRplay module
  (red herring — not a transport fault). Provisioning adds
  `/etc/ld.so.conf.d/usrlocal-sdrplay.conf` + `ldconfig` and sets
  `LD_LIBRARY_PATH=/usr/local/lib` in the unit so the loader finds it.
- **Client must select the remote device:** bare `driver=remote` makes the server
  open its *first* enumerable device (here the busy RTL2838 → `usb_claim_interface
  error -6`). Always pass `remote:driver=sdrplay` (from the registry `soapy_args`).
- The `sdr-source@` unit is deliberately **not enabled** (no boot start) — it
  would double-claim the dx-R2 against the boot-time `sdr-fm@active`. Start it by
  hand only inside an attended window. A `systemd-run --on-active` dead-man timer
  (stop source + start radio) guards the window against a dropped session.
