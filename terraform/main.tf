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
}

# Tier 1 — Acquisition (Pi, bare metal). NO container resource.
module "pi_acquisition" {
  source = "./modules/pi-acquisition"

  pi_host              = var.pi_host
  ssh_user             = var.pi_ssh_user
  ssh_private_key_path = var.ssh_private_key_path
  devices              = local.present_devices
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
  icecast_host            = var.distribution_ip
  icecast_source_password = var.icecast_source_password
}
