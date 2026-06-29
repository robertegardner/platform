# Tier 3 (extra) — adsb-feeder: rack LXC running the sdr-enthusiasts ultrafeeder
# (Docker) as the single ADS-B hub. Ingests p24's decoded Beast (1090) + UAT
# (978), aggregates with readsb, serves tar1090 (adsb.rg2.io), fans out to
# FlightAware/FR24/ADSBx + MLAT, and re-serves Beast (30005) + SBS (30003) for
# local consumers (the scoreboard LED matrix). No USB — network ingest only.
# Pattern copied from module.goes-archive / module.distribution. No depends_on
# the pi-adsb module (a down decoder is a runtime concern).

terraform {
  required_providers {
    proxmox = {
      source = "bpg/proxmox"
    }
  }
}

resource "proxmox_virtual_environment_container" "adsb_feeder" {
  node_name = var.node
  vm_id     = var.vmid
  pool_id   = var.pool_name

  description = "ADS-B hub (ultrafeeder, adsb.rg2.io) — managed by Terraform"
  tags        = ["adsb", "platform"]

  initialization {
    hostname = "adsb-feeder"

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
    # tar1090 globe_history/graphs + Docker images + ultrafeeder state.
    size = 16
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
    # Create-only args the Proxmox API never returns on read — ignore so taint +
    # apply stays safe (see the distribution module for the full rationale).
    ignore_changes = [tags, initialization[0].user_account, operating_system[0].template_file_id]
  }
}

resource "null_resource" "provision" {
  depends_on = [proxmox_virtual_environment_container.adsb_feeder]

  triggers = {
    container_id   = proxmox_virtual_environment_container.adsb_feeder.vm_id
    provision_hash = sha256(local.provision_script)
    compose_hash   = filesha256("${path.module}/docker-compose.yml")
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
    destination = "/tmp/provision-adsb-feeder.sh"
  }

  # The ultrafeeder compose file (no template vars; all runtime config rides in
  # /etc/adsb-feeder/feeders.env, written keep-if-absent by the provision script).
  provisioner "file" {
    source      = "${path.module}/docker-compose.yml"
    destination = "/tmp/docker-compose.yml"
  }

  # Single && chain so a failing script can't be masked by rm -f exiting 0
  # (remote-exec inline runs without set -e).
  provisioner "remote-exec" {
    inline = [
      "chmod +x /tmp/provision-adsb-feeder.sh && /tmp/provision-adsb-feeder.sh && rm -f /tmp/provision-adsb-feeder.sh",
    ]
  }
}

locals {
  provision_script = templatefile("${path.module}/provision-adsb-feeder.sh.tpl", {
    p24_host     = var.p24_host
    tar1090_port = var.tar1090_port
  })
}

output "ip" {
  value = var.ip
}

output "vmid" {
  value = var.vmid
}

output "tar1090_url" {
  value = "http://${var.ip}:${var.tar1090_port}/"
}
