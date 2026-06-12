# Tier 2 — Distribution: rack Icecast hosting all audio mounts (mount registry:
# terraform/registry/mounts.json). NPMplus repoints icecast.rg2.io here at
# cutover — that is a manual, attended step documented in docs/deployment_notes.md,
# NOT something this module does. Pattern copied from homelab-monitor's
# module.monitoring.

terraform {
  required_providers {
    proxmox = {
      source = "bpg/proxmox"
    }
  }
}

resource "proxmox_virtual_environment_container" "distribution" {
  node_name = var.node
  vm_id     = var.vmid
  pool_id   = var.pool_name

  description = "Distribution tier: Icecast (all audio mounts) — managed by Terraform"
  tags        = ["distribution", "platform"]

  initialization {
    hostname = "distribution"

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
    size         = 8
  }

  cpu {
    cores        = 1
    architecture = "amd64"
  }

  memory {
    dedicated = 1024
    swap      = 512
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
  depends_on = [proxmox_virtual_environment_container.distribution]

  triggers = {
    container_id   = proxmox_virtual_environment_container.distribution.vm_id
    provision_hash  = sha256(local.provision_script)
    fm_duck_hash    = filesha256("${path.module}/fm_duck.py")
    icy_pusher_hash = filesha256("${path.module}/icy_pusher.py")
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
    destination = "/tmp/provision-icecast.sh"
  }

  # The fm-duck daemon (talk-ducked /fm-duck.mp3 relay). Pushed as a plain
  # file — no template vars in it; the secret rides in /etc/fm-duck.env,
  # written by the provision script.
  provisioner "file" {
    source      = "${path.module}/fm_duck.py"
    destination = "/tmp/fm_duck.py"
  }

  # icy-pusher daemon (now-playing -> ICY StreamTitle for network streamers).
  provisioner "file" {
    source      = "${path.module}/icy_pusher.py"
    destination = "/tmp/icy_pusher.py"
  }

  # Single && chain so a failing script can't be masked by the rm -f exiting 0
  # (remote-exec inline runs without set -e — bit us on radio-compute 2026-06-10).
  provisioner "remote-exec" {
    inline = [
      "chmod +x /tmp/provision-icecast.sh && /tmp/provision-icecast.sh && rm -f /tmp/provision-icecast.sh",
    ]
  }
}

locals {
  provision_script = templatefile("${path.module}/provision-icecast.sh.tpl", {
    icecast_hostname = var.icecast_hostname
    source_password  = var.icecast_source_password
    admin_password   = var.icecast_admin_password
  })
}

output "ip" {
  value = var.ip
}

output "vmid" {
  value = var.vmid
}

output "status_url" {
  value = "http://${var.ip}:8000/status-json.xsl"
}
