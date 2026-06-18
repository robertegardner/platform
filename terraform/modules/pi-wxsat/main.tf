# Tier 1 (extra) — Weather-sat acquisition on the OUTDOOR ADS-B Pi (p24).
# Bare metal: null_resource + remote-exec over SSH, NO container. p24 is a live
# ADS-B feeder — never destroy/recreate; everything here is build-if-absent and
# selects the Nooelec strictly by its unique serial so the ADS-B dongles are
# never touched.

locals {
  # The wxsat domain holds exactly one device (nooelec-wx). one() errors if that
  # ever stops being true, which is the signal we want.
  dev = one(values(var.devices))

  provision_script = templatefile("${path.module}/provision-wxsat.sh.tpl", {
    serial    = try(local.dev.serial, "wxsat0001")
    bind_addr = var.rtltcp_bind
    port      = try(local.dev.port, 1234)
    gain      = var.rtltcp_gain
  })
}

resource "null_resource" "provision" {
  triggers = {
    provision_hash = sha256(local.provision_script)
    devices        = jsonencode(var.devices)
  }

  connection {
    type        = "ssh"
    host        = var.wxsat_host
    user        = var.ssh_user
    private_key = file(pathexpand(var.ssh_private_key_path))
    timeout     = "20m"
  }

  provisioner "remote-exec" {
    inline = ["echo 'SSH ready on '$(hostname)"]
  }

  provisioner "file" {
    content     = local.provision_script
    destination = "/tmp/provision-wxsat.sh"
  }

  # remote-exec runs WITHOUT set -e — chain so a failure isn't masked as success.
  provisioner "remote-exec" {
    inline = [
      "chmod +x /tmp/provision-wxsat.sh && sudo /tmp/provision-wxsat.sh && rm -f /tmp/provision-wxsat.sh",
    ]
  }
}
