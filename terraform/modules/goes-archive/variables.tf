# goes-archive — rack LXC that pulls GOES image products off goes.srvr, keeps a
# 7-day rolling archive, and serves the gallery + the weather2 headline API
# (goes.rg2.io). Container pattern copied from modules/distribution.

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

variable "goes_host" {
  description = "GOES Pi to pull products from (hostname or IP)"
  type        = string
}

variable "goes_ssh_user" {
  description = "SSH user on the GOES Pi for the rsync pull"
  type        = string
  default     = "rgardner"
}

variable "goes_output_dir" {
  description = "SatDump output dir on the GOES Pi"
  type        = string
  default     = "/home/rgardner/goes_output"
}

variable "pull_interval_sec" {
  description = "How often the rack rsync-pulls new products (seconds)"
  type        = number
  default     = 60
}

variable "archive_retention_days" {
  description = "How long the rack keeps products (days)"
  type        = number
  default     = 7
}

variable "gallery_port" {
  description = "Port the gallery/API HTTP service listens on"
  type        = number
  default     = 8095
}

variable "public_base" {
  description = "Public base URL for absolute image links in /api/goes/latest (the weather2 embed)"
  type        = string
  default     = "https://goes.rg2.io"
}
