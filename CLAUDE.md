d

The acquisition + distribution tier of the SDR homelab. The Pi acquires raw
samples and serves them on the network; the rack does all DSP and serves all
streams. Authoritative design lives in `docs/` — read
`docs/PLATFORM_V2_ARCHITECTURE.md` and `docs/deployment-notes.md` before changing
anything. Compute lives in the sibling repos `radio` (v2) and `scanner` (v2);
this repo owns the device registry, the source/mount contracts, and the Terraform
that stands the whole thing up.

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

All hosts are on the **Server VLAN → `vlan_id = 0`** (native untagged). The Pi
and LXCs are co-VLAN, so there's no routing between acquisition and compute.

## Repo layout

- `terraform/` — root (`main.tf` wires the modules) + `modules/{pi-acquisition,
  radio-compute,scanner-compute,distribution}`
- `terraform/modules/*/provision-*.sh.tpl` — bash provisioning rendered by
  `templatefile()`, run via `remote-exec` over SSH from thebeast
- `docs/` — `PLATFORM_V2_ARCHITECTURE.md`, `deployment-notes.md`, the registries
- container resource + Proxmox provider: copy the pattern from homelab-monitor's
  `module.monitoring` — do not re-derive the provider/token wiring

## Deploying

- `terraform` runs on thebeast as `deploy` (reuse the homelab deploy key). Its
  key must be authorized on the Pi (`rgardner`, passwordless sudo for installs)
  and in each LXC.
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
  clobber UI/manual state); `icecast.xml` only if absent.
- **One client per device source.** The scanner scheduler holds one persistent
  client to the R2 and retunes in place — it does not open/close repeatedly.
- **Wire format:** CS16 for dx-R2/Airspys, CU8 for the RTL v4; set client-side at
  connect (in the registry). Hold dx-R2 **≤8 Msps** on a single USB hub.
- **Unprivileged LXCs** — no USB passthrough, no device nodes (samples arrive
  over the network). Don't request privileged containers.
- **Retired, do not reintroduce:** the wxsat skip-when-listening gate (Meteor is
  on its own RTL v4 — no contention), the scanner's satellite-preemption job
  (Meteor is radio-domain now), and any RF/GPIO antenna switch.
- **Icecast is rack-side now** (`distribution`); `icecast.rg2.io` repoints there
  via NPMplus. Audio never traverses the Pi link — only outbound samples do.

## Bring-up order

1. `pi-acquisition` — verify each device streams raw to a client on the Server
   VLAN (no DSP yet).
2. `distribution` — Icecast + NPMplus routing; repoint `icecast.rg2.io`.
3. `scanner-compute` — repoint op25 to `driver=remote`; confirm P25 lock and that
   the Pi throttle is gone with op25 rack-side.
4. `radio-compute` — mux/stereo/AM/SatDump against remote sources, per the radio
   repo's `MULTISTATION_STEREO_BUILD.md`.
