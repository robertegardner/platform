# Tier 3 — Scanner compute (rack LXC 901, 192.168.6.83): P25 decode (op25) +
# later AIS/ACARS/ATC, consuming samples over SoapyRemote from the acquisition
# Pi. Interim source is the rtl-2838 (the dongle SDRTrunk used Pi-side); the
# Airspy R2 joins by flipping the registry — same transport, same client path.
# Pattern copied from module.distribution / homelab-monitor's module.monitoring.

terraform {
  required_providers {
    proxmox = {
      source = "bpg/proxmox"
    }
  }
}

resource "proxmox_virtual_environment_container" "scanner_compute" {
  node_name = var.node
  vm_id     = var.vmid
  pool_id   = var.pool_name

  description = "Scanner compute: op25 P25 decode + scanner domain jobs — managed by Terraform"
  tags        = ["platform", "scanner"]

  initialization {
    hostname = "scanner-compute"

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
    size         = 16
  }

  cpu {
    cores        = 2
    architecture = "amd64"
  }

  memory {
    dedicated = 2048
    swap      = 1024
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
    # user_account.keys and template_file_id are create-only args the Proxmox
    # API never returns on read, so re-importing this container (e.g. after a
    # lost state file) would otherwise force a destroy/recreate. They don't
    # change in practice — ignore them so `taint + apply` stays safe.
    ignore_changes = [tags, initialization[0].user_account, operating_system[0].template_file_id]
  }
}

resource "null_resource" "provision" {
  depends_on = [proxmox_virtual_environment_container.scanner_compute]

  triggers = {
    container_id   = proxmox_virtual_environment_container.scanner_compute.vm_id
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
    destination = "/tmp/provision-scanner.sh"
  }

  # op25 pulls the gnuradio dev stack and compiles — allow a long first run.
  # Single && chain: inline lines run as one generated script WITHOUT set -e,
  # so an unchained failing script would be masked by the rm -f exiting 0 and
  # the resource would falsely report success (bit us 2026-06-10).
  provisioner "remote-exec" {
    inline = [
      "chmod +x /tmp/provision-scanner.sh && /tmp/provision-scanner.sh && rm -f /tmp/provision-scanner.sh",
    ]
  }
}

locals {
  # remote:driver=<x> for each device, derived from the registry soapy_args
  # (e.g. "driver=rtlsdr" -> "rtlsdr"). Bare driver=remote would make the
  # server open its first enumerable device — always select explicitly.
  devices_rendered = {
    for id, d in var.devices : id => merge(d, {
      remote_driver = replace(d.soapy_args, "driver=", "")
      sample_rate   = try(d.sample_rate_default, try(d.sample_rate_max, 2400000))
    })
  }

  # The device the decode units bind to. Sorted-first is deliberate: when the
  # Airspy R2 flips present alongside the interim rtl-2838, "airspy-r2" sorts
  # first and the units retarget to it on re-apply.
  active_source = length(var.devices) > 0 ? sort(keys(var.devices))[0] : ""

  provision_script = templatefile("${path.module}/provision-scanner.sh.tpl", {
    devices                 = local.devices_rendered
    active_source           = local.active_source
    icecast_host            = var.icecast_host
    icecast_port            = var.icecast_port
    icecast_source_password = var.icecast_source_password
    whisper_token           = var.whisper_token
    rtltcp_bridge_py        = file("${path.module}/rtltcp_bridge.py")
    monitor_stream_py       = file("${path.module}/monitor_stream.py")
  })
}

output "ip" {
  value = var.ip
}

output "vmid" {
  value = var.vmid
}
