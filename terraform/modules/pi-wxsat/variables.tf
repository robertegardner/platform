# pi-wxsat — provisions the Nooelec (Meteor V-dipole) on the outdoor ADS-B Pi
# (p24.srvr) as a thin rtl_tcp source. Bare metal, like pi-acquisition: no
# container. All decode + storage live on the rack (radio-compute).

variable "wxsat_host" {
  description = "Hostname/IP of the outdoor ADS-B Pi hosting the Nooelec (p24)"
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
  description = "The wxsat-domain device subset (exactly one: nooelec-wx)"
  type        = any
}

variable "rtltcp_bind" {
  description = "Address rtl_tcp binds on p24 (0.0.0.0 = all LAN interfaces)"
  type        = string
  default     = "0.0.0.0"
}

variable "rtltcp_gain" {
  description = "Default rtl_tcp tuner gain (tenths of dB; empty = AGC). SatDump sets gain per pass over the rtl_tcp protocol, so empty is usually fine."
  type        = string
  default     = ""
}
