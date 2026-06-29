# adsb-feeder — rack LXC running the sdr-enthusiasts ultrafeeder (Docker) as the
# single ADS-B hub: ingests p24's Beast/UAT, serves tar1090 (adsb.rg2.io), and
# fans out to FlightAware/FR24/ADSBx + MLAT. Container pattern copied from
# modules/distribution / modules/goes-archive.

variable "vmid" {
  description = "Container vmid"
  type        = number
}

variable "ip" {
  description = "Static IPv4 of the container"
  type        = string
}

variable "prefix" {
  description = "IPv4 prefix length"
  type        = number
  default     = 24
}

variable "gw" {
  description = "IPv4 gateway"
  type        = string
}

variable "vlan_id" {
  description = "VLAN id (Server = 0, native untagged)"
  type        = number
}

variable "node" {
  description = "Proxmox node name"
  type        = string
}

variable "storage" {
  description = "Datastore for the root disk"
  type        = string
}

variable "template" {
  description = "LXC template file id"
  type        = string
}

variable "bridge" {
  description = "Proxmox bridge"
  type        = string
}

variable "pool_name" {
  description = "Proxmox resource pool (null = none; deploy token lacks Pool.Allocate)"
  type        = string
  default     = null
}

variable "ssh_public_key" {
  description = "Public key for the container root user"
  type        = string
}

variable "ssh_private_key_path" {
  description = "Private key used to provision over SSH"
  type        = string
}

variable "p24_host" {
  description = "p24 (the ADS-B decoder Pi) IP for Beast/UAT ingest"
  type        = string
  default     = "192.168.6.141"
}

variable "tar1090_port" {
  description = "Host port mapped to ultrafeeder tar1090 (container :80)"
  type        = number
  default     = 8080
}
