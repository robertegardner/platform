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

# Tiers 2/3 — stubs for now (no resources). They exist so the root wires cleanly
# and later phases drop resources in without restructuring.
module "distribution" {
  source = "./modules/distribution"
}

module "scanner_compute" {
  source = "./modules/scanner-compute"
}

module "radio_compute" {
  source = "./modules/radio-compute"
}
