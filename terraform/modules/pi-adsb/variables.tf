# pi-adsb — provisions the standalone ADS-B Pi (p24) as a DECODE-ONLY platform
# node: readsb (1090ES) + dump978-fa (978 UAT) serving Beast/SBS on the LAN for
# the rack adsb-feeder hub. Bare metal, like pi-acquisition/pi-wxsat: no
# container. p24 is a LIVE production feeder — never destroy/recreate.

variable "adsb_host" {
  description = "Hostname/IP of the ADS-B Pi (p24)"
  type        = string
}

variable "ssh_user" {
  description = "SSH user on p24 (passwordless sudo for installs/systemctl)"
  type        = string
}

variable "ssh_private_key_path" {
  description = "Private key thebeast's deploy user uses to reach p24"
  type        = string
}

variable "devices" {
  description = "The adsb-domain device subset (adsb-1090 + adsb-978)"
  type        = any
}
