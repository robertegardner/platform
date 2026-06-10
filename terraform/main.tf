# Root — reads the device registry and wires the four modules.
#
# The device registry is the source of truth for what is plugged in, where it is
# served, and who owns it (it replaces the dead RF switch). The provisioner only
# iterates devices marked `present: true`, so flipping a device to present and
# re-applying is how each new tuner joins the platform.

locals {
  registry        = jsondecode(file("${path.root}/registry/devices.json"))
  present_devices = { for id, d in local.registry.devices : id => d if d.present }
}

# Tier 1 — Acquisition (Pi, bare metal). NO container resource.
module "pi_acquisition" {
  source = "./modules/pi-acquisition"

  pi_host              = var.pi_host
  ssh_user             = var.pi_ssh_user
  ssh_private_key_path = var.ssh_private_key_path
  devices              = local.present_devices
}

# Proxmox resource pool for the platform LXCs (parallel to homelab-monitor's).
resource "proxmox_virtual_environment_pool" "platform" {
  pool_id = var.pool_name
  comment = "SDR platform V2 — distribution + compute LXCs (Terraform-managed)"
}

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
  pool_name            = proxmox_virtual_environment_pool.platform.pool_id
  ssh_public_key       = var.ssh_public_key
  ssh_private_key_path = var.ssh_private_key_path

  icecast_hostname        = var.icecast_hostname
  icecast_source_password = var.icecast_source_password
  icecast_admin_password  = var.icecast_admin_password
}

# Tier 3 — stubs for now (no resources). They exist so the root wires cleanly
# and later phases drop resources in without restructuring.
# Reserved: scanner-compute = vmid_base+1 / .83, radio-compute = vmid_base+2 / .84.
module "scanner_compute" {
  source = "./modules/scanner-compute"
}

module "radio_compute" {
  source = "./modules/radio-compute"
}
