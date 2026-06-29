# Tier 3 (extra) — goes-archive: rack LXC that mirrors GOES image products off
# goes.srvr, keeps a 7-day rolling archive, and serves the browsable gallery +
# the weather2 headline API (goes.rg2.io). Pattern copied from module.distribution
# (which copied homelab-monitor's module.monitoring). No depends_on the pi-goes
# module: a down decoder / unreachable Pi is a runtime concern (the pull just
# retries; the gallery serves whatever is already archived).

terraform {
  required_providers {
    proxmox = {
      source = "bpg/proxmox"
    }
  }
}

resource "proxmox_virtual_environment_container" "goes_archive" {
  node_name = var.node
  vm_id     = var.vmid
  pool_id   = var.pool_name

  description = "GOES archive + gallery (goes.rg2.io) — managed by Terraform"
  tags        = ["goes", "platform"]

  initialization {
    hostname = "goes-archive"

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
    # ~7 GB/day of IMAGES+EMWIN x 7 days ~= 50 GB; 64 leaves headroom + OS.
    size = 64
  }

  cpu {
    cores        = 2
    architecture = "amd64"
  }

  memory {
    dedicated = 2048
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
    # user_account.keys and template_file_id are create-only args the Proxmox
    # API never returns on read — ignore so taint + apply stays safe (see the
    # distribution module for the full rationale).
    ignore_changes = [tags, initialization[0].user_account, operating_system[0].template_file_id]
  }
}

resource "null_resource" "provision" {
  depends_on = [proxmox_virtual_environment_container.goes_archive]

  triggers = {
    container_id   = proxmox_virtual_environment_container.goes_archive.vm_id
    provision_hash = sha256(local.provision_script)
    gallery_hash   = filesha256("${path.module}/goes_gallery.py")
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
    destination = "/tmp/provision-goes-archive.sh"
  }

  # The gallery/API service. Pushed as a plain file (no template vars in it; all
  # config rides in /etc/goes-archive/goes.env, written by the provision script).
  provisioner "file" {
    source      = "${path.module}/goes_gallery.py"
    destination = "/tmp/goes_gallery.py"
  }

  # Single && chain so a failing script can't be masked by rm -f exiting 0
  # (remote-exec inline runs without set -e).
  provisioner "remote-exec" {
    inline = [
      "chmod +x /tmp/provision-goes-archive.sh && /tmp/provision-goes-archive.sh && rm -f /tmp/provision-goes-archive.sh",
    ]
  }
}

locals {
  provision_script = templatefile("${path.module}/provision-goes-archive.sh.tpl", {
    goes_host       = var.goes_host
    goes_ssh_user   = var.goes_ssh_user
    goes_output_dir = var.goes_output_dir
    pull_interval   = var.pull_interval_sec
    retention_days  = var.archive_retention_days
    gallery_port    = var.gallery_port
    public_base     = var.public_base
  })
}

output "ip" {
  value = var.ip
}

output "vmid" {
  value = var.vmid
}

output "gallery_url" {
  value = "http://${var.ip}:${var.gallery_port}/"
}
