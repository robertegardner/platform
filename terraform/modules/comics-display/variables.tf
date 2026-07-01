# comics-display — rack LXC that scrapes a rotating pool of classic comics
# (XKCD, Calvin and Hobbes, The Far Side, …), renders each to the Seeed
# reTerminal E1002's 800x480 Spectra-6 palette, and serves the current pick at a
# stable URL for the panel to pull on each wake. Container pattern copied from
# modules/dashboard. No depends_on anything — a down comic host is a runtime
# concern (the source degrades to its last good frame).

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

variable "comics_port" {
  description = "Port the comics HTTP service listens on"
  type        = number
  default     = 8080
}

variable "refresh_sec" {
  description = "Seconds a scraped frame stays fresh before a re-pull (comics update at most daily)"
  type        = number
  default     = 21600
}

variable "auto_advance_sec" {
  description = "Wall-clock auto-advance for the web preview; 0 = device-driven only (each /next.png advances)"
  type        = number
  default     = 0
}

variable "timezone" {
  description = "Local tz used to pick 'today' for date-based sources (GoComics)"
  type        = string
  default     = "America/Chicago"
}
