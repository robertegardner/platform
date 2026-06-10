# Tier 1 — Acquisition. The Pi is BARE METAL: null_resource + remote-exec over
# SSH, NO container resource. It is the live radio host — never destroy/recreate.
# Everything the provisioner does is build-if-absent / re-run safe.

locals {
  provision_script = templatefile("${path.module}/provision-pi.sh.tpl", {
    devices = var.devices
  })
}

resource "null_resource" "provision" {
  triggers = {
    provision_hash = sha256(local.provision_script)
    devices        = jsonencode(var.devices)
  }

  connection {
    type        = "ssh"
    host        = var.pi_host
    user        = var.ssh_user
    private_key = file(pathexpand(var.ssh_private_key_path))
    timeout     = "20m"
  }

  # Readiness check.
  provisioner "remote-exec" {
    inline = ["echo 'SSH ready on '$(hostname)"]
  }

  # Upload the rendered provisioning script.
  provisioner "file" {
    content     = local.provision_script
    destination = "/tmp/provision-pi.sh"
  }

  # Run it as root (passwordless sudo), then clean up.
  provisioner "remote-exec" {
    inline = [
      "chmod +x /tmp/provision-pi.sh",
      "sudo /tmp/provision-pi.sh",
      "rm -f /tmp/provision-pi.sh",
    ]
  }
}
