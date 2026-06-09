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
