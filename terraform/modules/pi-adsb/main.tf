# Tier 1 (extra) — ADS-B decode-only on p24 (standalone outdoor feeder Pi).
# Bare metal: null_resource + remote-exec over SSH, NO container. p24 is a LIVE
# production feeder — never destroy/recreate. Everything install-if-absent; the
# readsb config is marker-guarded so hand-tuned gain survives a re-apply. SDRs
# selected BY SERIAL, never index (p24's enumeration order is reversed).

locals {
  # Pick each band's device by role (registry: adsb-1090es / adsb-978uat).
  by_role     = { for d in values(var.devices) : try(d.role, d.serial) => d }
  serial_1090 = try(local.by_role["adsb-1090es"].serial, "00001090")
  serial_978  = try(local.by_role["adsb-978uat"].serial, "00000001")
  gain_1090   = try(tostring(local.by_role["adsb-1090es"].gain), "auto")

  provision_script = templatefile("${path.module}/provision-adsb.sh.tpl", {
    serial_1090 = local.serial_1090
    serial_978  = local.serial_978
    gain_1090   = local.gain_1090
  })
}

resource "null_resource" "provision" {
  # No-op when no adsb device is present (present:false): don't touch p24.
  count = length(var.devices) > 0 ? 1 : 0

  triggers = {
    provision_hash = sha256(local.provision_script)
    devices        = jsonencode(var.devices)
  }

  connection {
    type        = "ssh"
    host        = var.adsb_host
    user        = var.ssh_user
    private_key = file(pathexpand(var.ssh_private_key_path))
    timeout     = "20m"
  }

  provisioner "remote-exec" {
    inline = ["echo 'SSH ready on '$(hostname)"]
  }

  provisioner "file" {
    content     = local.provision_script
    destination = "/tmp/provision-adsb.sh"
  }

  # remote-exec runs WITHOUT set -e — chain so a failure isn't masked as success.
  provisioner "remote-exec" {
    inline = [
      "chmod +x /tmp/provision-adsb.sh && sudo /tmp/provision-adsb.sh && rm -f /tmp/provision-adsb.sh",
    ]
  }
}
