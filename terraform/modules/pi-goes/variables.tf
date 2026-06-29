# pi-goes — provisions the GOES-reception Pi (goes.srvr): Nooelec SmArTee +
# Sawbird GOES LNA + dish. UNLIKE every other tier-1 node, this Pi DECODES:
# GOES is geostationary/continuous, so SatDump runs `live goes_hrit` here. Bare
# metal, like pi-acquisition/pi-wxsat: no container. The rack LXC goes-archive
# rsync-pulls the products and serves the gallery + weather2 API.

variable "goes_host" {
  description = "Hostname/IP of the GOES Pi (goes.srvr)"
  type        = string
}

variable "ssh_user" {
  description = "SSH user on the GOES Pi (passwordless sudo for installs/systemctl)"
  type        = string
}

variable "ssh_private_key_path" {
  description = "Private key thebeast's deploy user uses to reach the GOES Pi"
  type        = string
}

variable "devices" {
  description = "The goes-domain device subset (exactly one: goes)"
  type        = any
}

variable "prune_retention_hours" {
  description = "Keep only this many hours of goes_output on the Pi's small SD card (the rack pulls every minute, so 24h is a huge safety margin)"
  type        = number
  default     = 24
}

variable "goes_output_dir" {
  description = "SatDump live output dir on the Pi"
  type        = string
  default     = "/home/rgardner/goes_output"
}
