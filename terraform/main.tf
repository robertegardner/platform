# Root — reads the device registry and wires the four modules.
#
# The device registry is the source of truth for what is plugged in, where it is
# served, and who owns it (it replaces the dead RF switch). The provisioner only
# iterates devices marked `present: true`, so flipping a device to present and
# re-applying is how each new tuner joins the platform.

locals {
  registry        = jsondecode(file("${path.root}/registry/devices.json"))
  present_devices = { for id, d in local.registry.devices : id => d if d.present }

  # Each device is owned by exactly one compute domain (architecture doc); the
  # compute modules render their client configs from their domain's devices.
  scanner_devices = { for id, d in local.present_devices : id => d if d.domain == "scanner" }
  radio_devices   = { for id, d in local.present_devices : id => d if d.domain == "radio" }
  # Weather-sat domain (Meteor LRPT) lives on the outdoor ADS-B Pi (p24), served
  # as rtl_tcp and decoded on the rack — its own domain so it stays out of the
  # radio-compute device loops.
  wxsat_devices = { for id, d in local.present_devices : id => d if d.domain == "wxsat" }
  # GOES geostationary downlink lives on a dedicated Pi (goes.srvr) that DECODES
  # live (SatDump goes_hrit) — its own domain so it stays out of the radio loops.
  # The rack LXC goes-archive pulls the products and serves the gallery + weather2.
  goes_devices = { for id, d in local.present_devices : id => d if d.domain == "goes" }
  # ADS-B lives on the standalone outdoor Pi (p24) that DECODES both bands
  # (readsb 1090 + dump978-fa 978) and ships Beast to the rack adsb-feeder LXC,
  # which runs ultrafeeder (the hub) — its own domain, out of the other loops.
  adsb_devices = { for id, d in local.present_devices : id => d if d.domain == "adsb" }
  # Weather: the Davis Vantage station on the Pi Zero (weather2). The Zero is a
  # thin serial-over-TCP bridge; the rack weather-compute LXC runs weewx + the
  # web + uploads. Own domain, out of the SDR loops.
  weather_devices = { for id, d in local.present_devices : id => d if d.domain == "weather" }
}

# Tier 1 — Acquisition (Pi, bare metal). NO container resource.
module "pi_acquisition" {
  source = "./modules/pi-acquisition"

  pi_host              = var.pi_host
  ssh_user             = var.pi_ssh_user
  ssh_private_key_path = var.ssh_private_key_path
  devices              = local.present_devices
}

# Tier 1 (extra) — Weather-sat acquisition on the outdoor ADS-B Pi (p24). Bare
# metal, no container; thin rtl_tcp source for the Nooelec/Meteor dipole. No
# depends_on the rack: a down decoder is a runtime concern.
module "pi_wxsat" {
  source = "./modules/pi-wxsat"

  wxsat_host           = var.wxsat_host
  ssh_user             = var.wxsat_ssh_user
  ssh_private_key_path = var.ssh_private_key_path
  devices              = local.wxsat_devices
}

# Tier 1 (extra) — GOES reception + LIVE decode on goes.srvr (dedicated Pi 5).
# Bare metal, no container. goes.service (keep-if-absent) decodes GOES-19 HRIT;
# a local prune timer keeps the small SD card from filling. No depends_on the
# rack: the archive pull is a runtime concern.
module "pi_goes" {
  source = "./modules/pi-goes"

  goes_host            = var.goes_host
  ssh_user             = var.goes_ssh_user
  ssh_private_key_path = var.ssh_private_key_path
  devices              = local.goes_devices
}

# NOTE: no proxmox_virtual_environment_pool here — the deploy API token lacks
# Pool.Allocate (verified: HTTP 403 on create). Platform LXCs are identified by
# their "platform" tag instead. If a pool is ever wanted, create it once as
# root on thebeast and pass pool_name through to the modules.

# Tier 2 — Distribution (rack Icecast). No depends_on pi-acquisition by design:
# a down source is a runtime concern; hard ordering would block -target re-provisions.
module "distribution" {
  source = "./modules/distribution"

  vmid                 = var.vmid_base + 0
  ip                   = var.distribution_ip
  prefix               = var.prefix
  gw                   = var.gw_server
  vlan_id              = var.vlan_server
  node                 = var.pm_node
  storage              = var.lxc_storage
  template             = var.lxc_template
  bridge               = var.pve_bridge
  ssh_public_key       = var.ssh_public_key
  ssh_private_key_path = var.ssh_private_key_path

  icecast_hostname        = var.icecast_hostname
  icecast_source_password = var.icecast_source_password
  icecast_admin_password  = var.icecast_admin_password
}

# Tier 3 — Compute (rack LXCs). Built ahead of the radio hardware upgrades
# (re-sequenced 2026-06-10): scanner-compute decodes P25 off the interim
# rtl-2838 source now; radio-compute is toolchain-staged so the dx-R2 cutover
# and the HF+/RTL-v4 joins are registry flips + re-apply. No depends_on
# pi-acquisition or distribution by design (runtime concerns; hard ordering
# would block -target re-provisions).
module "scanner_compute" {
  source = "./modules/scanner-compute"

  vmid                 = var.vmid_base + 1
  ip                   = var.scanner_compute_ip
  prefix               = var.prefix
  gw                   = var.gw_server
  vlan_id              = var.vlan_server
  node                 = var.pm_node
  storage              = var.lxc_storage
  template             = var.lxc_template
  bridge               = var.pve_bridge
  ssh_public_key       = var.ssh_public_key
  ssh_private_key_path = var.ssh_private_key_path

  devices                 = local.scanner_devices
  icecast_host            = var.distribution_ip
  icecast_source_password = var.icecast_source_password
  whisper_token           = var.whisper_token
}

module "radio_compute" {
  source = "./modules/radio-compute"

  vmid                 = var.vmid_base + 2
  ip                   = var.radio_compute_ip
  prefix               = var.prefix
  gw                   = var.gw_server
  vlan_id              = var.vlan_server
  node                 = var.pm_node
  storage              = var.lxc_storage
  template             = var.lxc_template
  bridge               = var.pve_bridge
  ssh_public_key       = var.ssh_public_key
  ssh_private_key_path = var.ssh_private_key_path

  devices                 = local.radio_devices
  wxsat_devices           = local.wxsat_devices
  icecast_host            = var.distribution_ip
  icecast_source_password = var.icecast_source_password
  pi_host                 = var.pi_host
}

# Tier 3 (extra) — goes-archive LXC: pulls GOES products off goes.srvr, keeps a
# 7-day archive, serves the gallery + weather2 headline API (goes.rg2.io). No
# depends_on pi_goes (runtime concern; hard ordering would block -target).
module "goes_archive" {
  source = "./modules/goes-archive"

  vmid                 = var.vmid_base + 3
  ip                   = var.goes_archive_ip
  prefix               = var.prefix
  gw                   = var.gw_server
  vlan_id              = var.vlan_server
  node                 = var.pm_node
  storage              = var.lxc_storage
  template             = var.lxc_template
  bridge               = var.pve_bridge
  ssh_public_key       = var.ssh_public_key
  ssh_private_key_path = var.ssh_private_key_path

  goes_host     = var.goes_host
  goes_ssh_user = var.goes_ssh_user
}

# Tier 3 (extra) — adsb-feeder LXC: the ultrafeeder ADS-B hub. Ingests p24's
# Beast/UAT, runs tar1090 (adsb.rg2.io), fans out to FA/FR24/ADSBx + MLAT, and
# re-serves Beast/SBS for local consumers. No depends_on pi_adsb (runtime).
module "adsb_feeder" {
  source = "./modules/adsb-feeder"

  vmid                 = var.vmid_base + 4
  ip                   = var.adsb_feeder_ip
  prefix               = var.prefix
  gw                   = var.gw_server
  vlan_id              = var.vlan_server
  node                 = var.pm_node
  storage              = var.lxc_storage
  template             = var.lxc_template
  bridge               = var.pve_bridge
  ssh_public_key       = var.ssh_public_key
  ssh_private_key_path = var.ssh_private_key_path

  p24_host = var.adsb_host
}

# Tier 1 (extra) — pi-adsb: p24 decode-only (readsb 1090 + dump978-fa 978),
# Beast/SBS to the rack. No depends_on the rack (runtime concern).
module "pi_adsb" {
  source = "./modules/pi-adsb"

  adsb_host            = var.adsb_host
  ssh_user             = var.adsb_ssh_user
  ssh_private_key_path = var.ssh_private_key_path
  devices              = local.adsb_devices
}

# Tier 3 (extra) — weather-compute LXC: weewx 5 for the Davis Vantage (read over
# the Pi Zero's ser2net bridge) + Belchertown + uploads + nginx (bobgardner.org).
module "weather_compute" {
  source = "./modules/weather-compute"

  vmid                 = var.vmid_base + 5
  ip                   = var.weather_compute_ip
  prefix               = var.prefix
  gw                   = var.gw_server
  vlan_id              = var.vlan_server
  node                 = var.pm_node
  storage              = var.lxc_storage
  template             = var.lxc_template
  bridge               = var.pve_bridge
  ssh_public_key       = var.ssh_public_key
  ssh_private_key_path = var.ssh_private_key_path
}

# Tier 1 (extra) — pi-weather: the LOCAL Davis collector on the Pi Zero (weather2).
# weewx collection stays here; the archive DB replicates to weather-compute via
# Litestream. `cutover` defaults false (install Litestream idle; nothing changes
# live). Flip true to disable on-Zero reports + start replication.
module "pi_weather" {
  source = "./modules/pi-weather"

  weather_host         = var.weather_host
  ssh_user             = var.weather_ssh_user
  ssh_private_key_path = var.ssh_private_key_path
  devices              = local.weather_devices
  rack_host            = var.weather_compute_ip
  cutover              = var.weather_cutover
}
