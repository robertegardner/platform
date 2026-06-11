# platform

The acquisition + distribution tier of the SDR homelab. The Pi acquires raw
samples and serves them on the network; the rack does all DSP and serves all
streams. Authoritative design lives in `docs/` — read
`docs/PLATFORM_V2_ARCHITECTURE.md` and `docs/deployment_notes.md` before changing
anything (`docs/session_notes.md` is the quick "where were we" log). Compute
lives in the sibling repos `radio` (v2) and `scanner` (v2); this repo owns the
device registry, the source/mount contracts, and the Terraform that stands the
whole thing up.

## Current state (2026-06-10 night: V2 radio PAUSED — V1 hybrid restored)

- **RADIO = V1 hybrid:** DSP back on the Pi (`sdr-fm@active` unmasked,
  enabled; `sdr-source@dx-r2` disabled — the V1 radio owns the dx-R2 again),
  but it **publishes to the rack Icecast** (`ICECAST_HOST=192.168.6.82` in
  the Pi's active.env; stream.sh host is env-able, mirrored into the radio
  repo). Pi `sdr-captions` re-enabled. Rack FM units on .84 all disabled
  (`sdr-fm@active`, `fm-watch.timer`, `sdr-tuner`, `sdr-captions`).
  **WHY:** raw-IQ-over-network is unusable on the current topology — the Pi
  shares the attic camera flex whose 1G uplink carries 8 cameras + an
  HDHomeRun; SoapyRemote's line-rate microbursts tail-drop there (full
  diagnosis in deployment_notes.md). **Unpause when the dedicated attic run
  to the aggregation switch exists**; the V2 re-cutover is the documented
  switch steps (everything stays provisioned on .84).
- **P25 stays V2 on scanner-compute** (LXC **901**, .83): op25 on the interim
  `rtl-2838` (:55005, enabled at boot) → rack `/ems.mp3` — its 38 Mbps CU8
  survives the shared uplink acceptably. Interim-dark:
  `/ems-{fire,police,interop}`, `/monitor.mp3`, EMS transcripts. Scanner
  rollback path (if ever needed): SCHEDULER_EMS_DEFAULT=true + disable
  sdr-source@rtl-2838 + stop op25-ems/ems-stream.
- **Distribution:** `icecast.rg2.io` → rack (.82) via NPM; both mounts
  rack-served (`/fm.mp3` published FROM the Pi, `/ems.mp3` from .83). The
  Pi's icecast2 + its two relay blocks are now redundant (kept, harmless).
  Pi wlan0 is OFF (ARP flux — never re-enable on this wired node).
  RDS on 99.3 is weak/sparse (station-side, not a defect).
- **Distribution:** rack Icecast on LXC **900** (.82) sources BOTH mounts.
  `icecast.rg2.io` proxies to the **Pi's** Icecast, which carries on-demand
  relays for `/fm.mp3` + `/ems.mp3` (marked `platform-cutover` in
  icecast.xml). NPM repoint to .82 is LAST — it retires the relays and the
  Pi's icecast2. (An early NPM repoint before the fm cutover 404'd the public
  radio — don't repoint until every mount is rack-sourced.)
- **Waiting on hardware:** Airspy R2 (flip `airspy-r2` true + `rtl-2838`
  false, re-apply), HF+ and RTL v4 (registry flips). Before any >5 Msps stream
  into an LXC: raise `net.core.{r,w}mem_max` on **thebeast** (host kernel —
  read-only inside unprivileged LXCs).
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
  not the SatDump client.
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
- **`sdr-source@{dx-r2,rtl-2838}` are enabled at boot** (post-cutover: the
  rack compute LXCs are their only clients). The old rule — sources disabled
  because the Pi radio claimed the dx-R2 — is retired along with
  `sdr-fm@active` (now masked; unmask only for rollback). Devices remain
  single-client: never point a second consumer at a served device.
- **`remote-exec` inline runs WITHOUT `set -e`** — always chain
  `script && rm -f script` in one line or failures are masked as success.
- **`grep -q` after a pipe + `pipefail` = SIGPIPE race** (fails on genuine
  matches). Use `grep ... >/dev/null` in provisioning checks.
- **op25:** R820T gain element is `TUNER` (wrong names silently ignored →
  deaf dongle); audio to Icecast goes via liquidsoap + audio.py (`mksafe` —
  op25 emits UDP PCM only during calls; bare ffmpeg stalls and drops the
  mount); needs `python3-setuptools` on noble.

## Bring-up order (state at end of 2026-06-10)

1. ✅ `pi-acquisition` — dx-R2 proven (8 Msps CS16, Gate 0B GO). Remaining
   devices join by flipping `present: true` in the registry + re-apply.
2. ✅ `distribution` — rack Icecast live; **NPM `icecast.rg2.io` → .82 (done,
   user)**. Both mounts rack-served.
3. ✅ `scanner-compute` — op25 LIVE on the interim rtl-2838; `/ems.mp3`
   rack-sourced. Remaining: scanner v2 app work on Airspy R2 arrival.
4. ⏸️ `radio-compute` — **PAUSED, rolled back to V1-hybrid** (attic uplink
   can't carry IQ microbursts — see Current state). Everything stays
   provisioned on .84. **Unpause = dedicated attic ethernet run**, then:
   stop Pi `sdr-fm@active` (+disable), enable `sdr-source@dx-r2`, enable
   `.84` units (`sdr-fm@active`, `sdr-tuner`, `sdr-captions`,
   `fm-watch.timer`), verify; add `tc fq maxrate` pacing on the Pi as
   belt-and-braces. Then the stereo mux (radio repo v2) targets .84.

## NPM proxy map (user-managed; TARGET state for the Android app — see
## deployment_notes "Android app integration")

- `icecast.rg2.io` → 192.168.6.82:8000 (rack Icecast — all public audio)
- `scanner.rg2.io` → 192.168.6.83:8080 (op25 console; legacy page is the
  data-complete one under single-receiver rx.py)
- `radio.rg2.io` → **radio.srvr:8080** (live V1 tuner API+UI — the Android
  app's radio backend; moves to .84:8080 at the radio unpause)
- `ems.rg2.io` → **192.168.6.83:8081** (scanner-api bridge — the Android
  app's scanner backend; deployed from the scanner repo). NEVER point it at
  the Pi's old scheduler — its MOSWIN job USB-resets the dongle out from
  under sdr-source@rtl-2838.
- `p25.rg2.io` → radio.srvr:8081 (the V1 scanner UI in READ-ONLY mode:
  /listen plays the live op25 feed with captions + the V1 archive pages.
  `SCANNER_UI_READONLY=true` makes it proxy the .83 bridge — it cannot
  reach the old scheduler. Created via tools/npm-proxy.py; note NPMplus
  cert API quirk: POST /api/nginx/certificates takes NO meta keys, and a
  cloned host serves the SOURCE's cert — issue a per-domain cert and PUT
  certificate_id after cloning.)
