# weather-compute — rack LXC running weewx 5 (Davis Vantage via the Pi Zero's
# serial-over-TCP bridge), the Belchertown + Seasons reports, the uploads
# (Wunderground/CWOP/PWSweather/AWEKAS + MQTT), and nginx serving the public site
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

variable "weather_host" {
  description = "The Pi Zero bridge (weather2) IP — weewx reads the Davis console via its ser2net TCP port"
  type        = string
  default     = "192.168.6.32"
}

variable "ser2net_port" {
  description = "ser2net TCP port on the bridge that exposes /dev/rfcomm0 (the Davis console)"
  type        = number
  default     = 3001
}
