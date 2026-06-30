# dashboard — rack LXC serving the unified platform landing page (home.rg2.io).
# A small stdlib-Python http.server that polls every other service's status API
# server-side and renders one Material-Design-3 tile per domain. Container pattern
# copied from module.goes-archive (which copied module.distribution). No
# depends_on the other modules: a down backend is a runtime concern — the tile
# just shows "offline" and the page keeps serving.

terraform {
  required_providers {
    proxmox = {
      source = "bpg/proxmox"
    }
  }
}

resource "proxmox_virtual_environment_container" "dashboard" {
  node_name = var.node
  vm_id     = var.vmid
  pool_id   = var.pool_name

  description = "Unified platform dashboard (home.rg2.io) — managed by Terraform"
  tags        = ["dashboard", "platform"]

  initialization {
    hostname = "dashboard"

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
    # Stores nothing but the OS + a one-file app — 8 GB is ample.
    size = 8
  }

  cpu {
    cores        = 1
    architecture = "amd64"
  }

  memory {
    dedicated = 512
    swap      = 256
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
    # API never returns on read — ignore so taint + apply stays safe (see the
    # distribution/goes-archive modules for the full rationale).
    ignore_changes = [tags, initialization[0].user_account, operating_system[0].template_file_id]
  }
}

resource "null_resource" "provision" {
  depends_on = [proxmox_virtual_environment_container.dashboard]

  triggers = {
    container_id   = proxmox_virtual_environment_container.dashboard.vm_id
    provision_hash = sha256(local.provision_script)
    app_hash       = filesha256("${path.module}/dashboard.py")
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
    destination = "/tmp/provision-dashboard.sh"
  }

  # The dashboard service. Pushed as a plain file (no template vars in it; all
  # config rides in /etc/dashboard/dashboard.env, written by the provision script).
  provisioner "file" {
    source      = "${path.module}/dashboard.py"
    destination = "/tmp/dashboard.py"
  }

  # Single && chain so a failing script can't be masked by rm -f exiting 0
  # (remote-exec inline runs without set -e).
  provisioner "remote-exec" {
    inline = [
      "chmod +x /tmp/provision-dashboard.sh && /tmp/provision-dashboard.sh && rm -f /tmp/provision-dashboard.sh",
    ]
  }
}

locals {
  provision_script = templatefile("${path.module}/provision-dashboard.sh.tpl", {
    dashboard_port = var.dashboard_port
    site_title     = var.site_title
    radio_base     = var.radio_base
    scanner_base   = var.scanner_base
    goes_base      = var.goes_base
    wx_base        = var.wx_base
    weather_base   = var.weather_base
    adsb_base      = var.adsb_base
    icecast_base   = var.icecast_base
  })
}

output "ip" {
  value = var.ip
}

output "vmid" {
  value = var.vmid
}

output "dashboard_url" {
  value = "http://${var.ip}:${var.dashboard_port}/"
}
