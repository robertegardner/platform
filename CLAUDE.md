# platform

The acquisition + distribution tier of the SDR homelab. The Pi acquires raw
samples and serves them on the network; the rack does all DSP and serves all
streams. Authoritative design lives in `docs/` — read
`docs/PLATFORM_V2_ARCHITECTURE.md` and `docs/deployment_notes.md` before changing
anything (`docs/session_notes.md` is the quick "where were we" log). Compute
lives in the sibling repos `radio` (v2) and `scanner` (v2); this repo owns the
device registry, the source/mount contracts, and the Terraform that stands the
whole thing up.

## Current state (2026-06-10, both domains cut over)

- **The Pi is now a pure acquisition node.** `sdr-source@dx-r2` (:55001) and
  `sdr-source@rtl-2838` (:55005) enabled at boot; ALL V1 DSP retired
  (`sdr-fm@active` disabled+**masked** — the tuner UI's restart path must not
  fight the source server; SDRTrunk off via `SCHEDULER_EMS_DEFAULT=false`).
- **P25 LIVE on scanner-compute** (LXC **901**, .83): op25 on the interim
  `rtl-2838` device → rack `/ems.mp3`. Interim-dark:
  `/ems-{fire,police,interop}`, `/monitor.mp3`, EMS transcripts.
- **FM LIVE on radio-compute** (LXC **902**, .84): `fm-stream.service` =
  V1-parity rx_fm+redsea+ffmpeg chain on the remote dx-R2 → rack `/fm.mp3`
  (retune: edit `/etc/radio-compute/fm.env` + restart). Interim-dead:
  tuner-UI retune, HD (nrsc5 mode), AM. The stereo/multistation mux is the
  radio repo's v2 project, targeting this LXC.
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

## Bring-up order

1. ✅ `pi-acquisition` — dx-R2 proven (8 Msps CS16, Gate 0B GO). Remaining
   devices join by flipping `present: true` in the registry + re-apply.
2. ✅ `distribution` — rack Icecast live + verified. ⏳ NPMplus repoint of
   `icecast.rg2.io` deferred to after the compute cutovers (it cuts ALL mounts
   at once — sources must already publish rack-side).
3. `scanner-compute` — repoint op25 to `driver=remote`; confirm P25 lock and that
   the Pi throttle is gone with op25 rack-side. Cut `ems*`/`monitor` mounts to
   the rack here.
4. `radio-compute` — mux/stereo/AM/SatDump against remote sources, per the radio
   repo's `MULTISTATION_STEREO_BUILD.md`. Cut `/fm.mp3` here; then the NPMplus
   repoint, last.
