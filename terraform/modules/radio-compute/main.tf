# Tier 3 — Radio compute (rack LXC 902, 192.168.6.84): FM mux/stereo + AM +
# Meteor/wxsat (SatDump), consuming samples over SoapyRemote from the Pi.
# This module provisions the TOOLCHAIN + registry-rendered source envs only;
# the radio repo's own deploy.sh owns app code (two-cadence rule). Nothing is
# started here — the dx-R2 is claimed by the live radio on the Pi until the
# radio-domain cutover, and the HF+ / RTL v4 join via registry flips when the
# hardware arrives. Pattern copied from module.distribution.

terraform {
  required_providers {
    proxmox = {
      source = "bpg/proxmox"
    }
  }
}

resource "proxmox_virtual_environment_container" "radio_compute" {
  node_name = var.node
  vm_id     = var.vmid
  pool_id   = var.pool_name

  description = "Radio compute: FM mux/stereo + AM + SatDump — managed by Terraform"
  tags        = ["platform", "radio"]

  initialization {
    hostname = "radio-compute"

    ip_config {
      ipv4 {
        address = "${var.ip}/${var.prefix}"
        gateway = var.gw
      }
    }

    user_account {
      keys = [trimspace(var.ssh_public_key)]
    }
  }

  network_interface {
    name     = "eth0"
    bridge   = var.bridge
    vlan_id  = var.vlan_id
    firewall = false
  }

  disk {
    datastore_id = var.storage
    size         = 32
  }

  cpu {
    cores        = 4
    architecture = "amd64"
  }

  memory {
    dedicated = 4096
    swap      = 2048
  }

  operating_system {
    template_file_id = var.template
    type             = "ubuntu"
  }

  features {
    nesting = true
  }

  unprivileged  = true
  started       = true
  start_on_boot = true

  lifecycle {
    ignore_changes = [tags]
  }
}

resource "null_resource" "provision" {
  depends_on = [proxmox_virtual_environment_container.radio_compute]

  triggers = {
    container_id   = proxmox_virtual_environment_container.radio_compute.vm_id
    provision_hash = sha256(local.provision_script)
    devices        = jsonencode(var.devices)
  }

  connection {
    type        = "ssh"
    host        = var.ip
    user        = "root"
    private_key = file(pathexpand(var.ssh_private_key_path))
    timeout     = "10m"
  }

  provisioner "remote-exec" {
    inline = ["cloud-init status --wait || true", "echo 'SSH ready'"]
  }

  provisioner "file" {
    content     = local.provision_script
    destination = "/tmp/provision-radio.sh"
  }

  # SatDump is a long source build on the first run. Single && chain: inline
  # lines run as one generated script WITHOUT set -e, so an unchained failing
  # script would be masked by the rm -f exiting 0 and the resource would
  # falsely report success (bit us 2026-06-10).
  provisioner "remote-exec" {
    inline = [
      "chmod +x /tmp/provision-radio.sh && /tmp/provision-radio.sh && rm -f /tmp/provision-radio.sh",
    ]
  }
}

locals {
  devices_rendered = {
    for id, d in var.devices : id => merge(d, {
      remote_driver = replace(d.soapy_args, "driver=", "")
      sample_rate   = try(d.sample_rate_default, try(d.sample_rate_max, 2400000))
    })
  }

  provision_script = templatefile("${path.module}/provision-radio.sh.tpl", {
    devices                 = local.devices_rendered
    icecast_host            = var.icecast_host
    icecast_port            = var.icecast_port
    icecast_source_password = var.icecast_source_password
    pi_host                 = var.pi_host
    noaa_stream_py          = file("${path.module}/noaa_stream.py")
    wx_alert_py             = file("${path.module}/wx_alert.py")
  })
}

output "ip" {
  value = var.ip
}

output "vmid" {
  value = var.vmid
}
