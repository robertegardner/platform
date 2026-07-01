# Tier 1 (extra) — GOES geostationary reception + live decode on goes.srvr.
# Bare metal: null_resource + remote-exec over SSH, NO container. goes.srvr is a
# live decode host — never destroy/recreate. Everything build-if-absent; the
# canonical goes.service is KEEP-IF-ABSENT so the user's hand-tuned gain/freq is
# never clobbered by a re-apply.

locals {
  # The goes domain holds exactly one device. one() errors if that ever stops
  # being true, which is the signal we want.
  dev = one(values(var.devices))

  provision_script = templatefile("${path.module}/provision-goes.sh.tpl", {
    frequency_hz = try(local.dev.freq_hz, 1694100000)
    samplerate   = try(local.dev.sample_rate_default, 2400000)
    gain         = try(local.dev.gain, 40)
    goes_serial  = try(local.dev.serial, "47360874")
    output_dir   = var.goes_output_dir
    prune_hours  = var.prune_retention_hours
    ssh_user     = var.ssh_user
    # goes-watch watchdog: restart goes.service if no new product lands within
    # watch_stale_min (SatDump can stall silently — process 'active', stream dead).
    # watch_grace_min suppresses action right after a (re)start to avoid loops.
    watch_stale_min = 10
    watch_grace_min = 5
  })
}

resource "null_resource" "provision" {
  # No-op when no goes device is present (present:false): don't touch goes.srvr.
  count = length(var.devices) > 0 ? 1 : 0

  triggers = {
    provision_hash = sha256(local.provision_script)
    devices        = jsonencode(var.devices)
    goes_aim_hash  = filesha256("${path.module}/goes_aim.py")
  }

  connection {
    type        = "ssh"
    host        = var.goes_host
    user        = var.ssh_user
    private_key = file(pathexpand(var.ssh_private_key_path))
    timeout     = "20m"
  }

  provisioner "remote-exec" {
    inline = ["echo 'SSH ready on '$(hostname)"]
  }

  provisioner "file" {
    content     = local.provision_script
    destination = "/tmp/provision-goes.sh"
  }

  # The dish-aiming tool (look angles + live SatDump peaking), deployed by the
  # provisioner as the goes-aim service.
  provisioner "file" {
    source      = "${path.module}/goes_aim.py"
    destination = "/tmp/goes_aim.py"
  }

  # remote-exec runs WITHOUT set -e — chain so a failure isn't masked as success.
  provisioner "remote-exec" {
    inline = [
      "chmod +x /tmp/provision-goes.sh && sudo /tmp/provision-goes.sh && rm -f /tmp/provision-goes.sh",
    ]
  }
}
