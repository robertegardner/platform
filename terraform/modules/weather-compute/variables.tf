# weather-compute — rack LXC, the REPORT-ONLY half of the weather2 fold. The Pi
# Zero replicates its weewx archive DB here via Litestream; this box restores it +
# runs the Belchertown + Seasons reports + serves the public site
# (weather.bobgardner.org). Container pattern copied from modules/adsb-feeder.

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

variable "replica_path" {
  description = "Local path where the Zero's Litestream replica is SFTP-pushed + restored from"
  type        = string
  default     = "/srv/weather-replica"
}

variable "db_path" {
  description = "Where the restored weewx archive DB lands (read by weectl report run)"
  type        = string
  default     = "/var/lib/weewx/weewx.sdb"
}

variable "litestream_version" {
  description = "Litestream release to install (install-if-absent, arch-matched)"
  type        = string
  default     = "0.3.13"
}

variable "report_interval_min" {
  description = "Minutes between replica restore + report regeneration (live tiles are MQTT-real-time, so the full report can lag a few minutes)"
  type        = number
  default     = 10
}
