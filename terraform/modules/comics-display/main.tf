# comics-display — rack LXC that scrapes a rotating pool of classic comics and
# renders each to the reTerminal E1002's 800x480 Spectra-6 palette, serving the
# current pick at a stable URL (the panel pulls /next.png on each deep-sleep
# wake). A small stdlib+Pillow http.server (comics.py) with a live source-
# management UI. Container pattern copied from module.dashboard. No depends_on:
# a down comic host is a runtime concern (source degrades to its last good frame).
#
# NOT wired into root main.tf yet — pick a vmid/ip and add a module block (see
# README). The app also runs standalone: `python3 comics.py`.

terraform {
  required_providers {
    proxmox = {
      source = "bpg/proxmox"
    }
  }
}

resource "proxmox_virtual_environment_container" "comics" {
  node_name = var.node
  vm_id     = var.vmid
  pool_id   = var.pool_name

  description = "Rotating comics for the reTerminal E1002 — managed by Terraform"
  tags        = ["comics", "platform"]

  initialization {
    hostname = "comics-display"

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
    # OS + one-file app + a handful of cached 800x480 frames — 8 GB is ample.
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
    # dashboard/goes-archive modules for the full rationale).
    ignore_changes = [tags, initialization[0].user_account, operating_system[0].template_file_id]
  }
}

resource "null_resource" "provision" {
  depends_on = [proxmox_virtual_environment_container.comics]

  triggers = {
    container_id   = proxmox_virtual_environment_container.comics.vm_id
    provision_hash = sha256(local.provision_script)
    app_hash       = filesha256("${path.module}/comics.py")
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
    destination = "/tmp/provision-comics.sh"
  }

  # The comics service. Pushed as a plain file (no template vars in it; all
  # config rides in /etc/comics-display/comics.env, written by the provisioner).
  provisioner "file" {
    source      = "${path.module}/comics.py"
    destination = "/tmp/comics.py"
  }

  # Single && chain so a failing script can't be masked by rm -f exiting 0
  # (remote-exec inline runs without set -e).
  provisioner "remote-exec" {
    inline = [
      "chmod +x /tmp/provision-comics.sh && /tmp/provision-comics.sh && rm -f /tmp/provision-comics.sh /tmp/comics.py",
    ]
  }
}

locals {
  provision_script = templatefile("${path.module}/provision-comics.sh.tpl", {
    comics_port      = var.comics_port
    refresh_sec      = var.refresh_sec
    auto_advance_sec = var.auto_advance_sec
    timezone         = var.timezone
  })
}

output "ip" {
  value = var.ip
}

output "vmid" {
  value = var.vmid
}

output "comics_url" {
  value = "http://${var.ip}:${var.comics_port}/"
}

output "device_url" {
  description = "The URL the reTerminal E1002 firmware fetches on each wake"
  value       = "http://${var.ip}:${var.comics_port}/next.png"
}
