# Tier 1 (extra) — weather acquisition bridge on the Pi Zero (weather2).
# Bare metal: null_resource + remote-exec over SSH, NO container. weather2 is a
# LIVE station node — never destroy/recreate. The `cutover` flag gates the
# disruptive switch (default false = install the bridge idle alongside the live
# local weewx).

locals {
  dev = one(values(var.devices))

  provision_script = templatefile("${path.module}/provision-weather.sh.tpl", {
    console_mac  = try(local.dev.console_mac, var.console_mac)
    ser2net_port = var.ser2net_port
    cutover      = var.cutover
  })
}

resource "null_resource" "provision" {
  # No-op when no weather device is present (present:false): don't touch weather2.
  count = length(var.devices) > 0 ? 1 : 0

  triggers = {
    provision_hash = sha256(local.provision_script)
    devices        = jsonencode(var.devices)
    cutover        = var.cutover
  }

  connection {
    type        = "ssh"
    host        = var.weather_host
    user        = var.ssh_user
    private_key = file(pathexpand(var.ssh_private_key_path))
    timeout     = "20m"
  }

  provisioner "remote-exec" {
    inline = ["echo 'SSH ready on '$(hostname)"]
  }

  provisioner "file" {
    content     = local.provision_script
    destination = "/tmp/provision-weather.sh"
  }

  # remote-exec runs WITHOUT set -e — chain so a failure isn't masked as success.
  provisioner "remote-exec" {
    inline = [
      "chmod +x /tmp/provision-weather.sh && sudo /tmp/provision-weather.sh && rm -f /tmp/provision-weather.sh",
    ]
  }
}
