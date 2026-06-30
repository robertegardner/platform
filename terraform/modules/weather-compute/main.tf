# Tier 3 (extra) — weather-compute: rack LXC, the REPORT-ONLY half of the weather2
# fold. The Pi Zero keeps collecting (Vantage DMPAFT only works over local BT
# serial) and replicates its archive DB here via Litestream; this box restores a
# faithful copy on a timer + runs `weectl report run` (Belchertown + Seasons) +
# serves the site via nginx. weewxd is masked (never collects/uploads). Pattern
# copied from module.adsb-feeder / module.goes-archive. No depends_on pi-weather
# (a down collector/replica is a runtime concern).

terraform {
  required_providers {
    proxmox = {
      source = "bpg/proxmox"
    }
  }
}

resource "proxmox_virtual_environment_container" "weather_compute" {
  node_name = var.node
  vm_id     = var.vmid
  pool_id   = var.pool_name

  description = "weewx report-only + Belchertown (weather.bobgardner.org) — managed by Terraform"
  tags        = ["weather", "platform"]

  initialization {
    hostname = "weather-compute"

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
    # weewx archive DB (~0.4 GB + growth) + generated HTML/graphs + report gen.
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
    ignore_changes = [tags, initialization[0].user_account, operating_system[0].template_file_id]
  }
}

resource "null_resource" "provision" {
  depends_on = [proxmox_virtual_environment_container.weather_compute]

  triggers = {
    container_id   = proxmox_virtual_environment_container.weather_compute.vm_id
    provision_hash = sha256(local.provision_script)
  }

  connection {
    type        = "ssh"
    host        = var.ip
    user        = "root"
    private_key = file(pathexpand(var.ssh_private_key_path))
    timeout     = "15m"
  }

  provisioner "remote-exec" {
    inline = ["cloud-init status --wait || true", "echo 'SSH ready'"]
  }

  provisioner "file" {
    content     = local.provision_script
    destination = "/tmp/provision-weather-compute.sh"
  }

  provisioner "remote-exec" {
    inline = [
      "chmod +x /tmp/provision-weather-compute.sh && /tmp/provision-weather-compute.sh && rm -f /tmp/provision-weather-compute.sh",
    ]
  }
}

locals {
  provision_script = templatefile("${path.module}/provision-weather-compute.sh.tpl", {
    replica_path        = var.replica_path
    db_path             = var.db_path
    litestream_version  = var.litestream_version
    report_interval_min = var.report_interval_min
  })
}

output "ip" {
  value = var.ip
}

output "vmid" {
  value = var.vmid
}

output "site_url" {
  value = "http://${var.ip}/"
}
