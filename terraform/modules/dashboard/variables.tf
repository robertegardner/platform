# dashboard — rack LXC serving the unified platform landing page (home.rg2.io).
# A stdlib-Python http.server that polls every other service's status API
# server-side (avoids HTTPS->HTTP mixed-content from the browser) and renders one
# Material-Design-3 tile per domain. Container pattern copied from modules/goes-archive.

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

variable "dashboard_port" {
  description = "Port the dashboard HTTP service listens on"
  type        = number
  default     = 8080
}

variable "site_title" {
  description = "Title shown in the app bar / browser tab"
  type        = string
  default     = "rg2.io platform"
}

# --- Backend bases the aggregator polls (HTTP, on the Server VLAN). Defaults
#     match the current host map; passed from root so they track the *_ip vars. --
variable "radio_base" {
  description = "radio-compute tuner API base (stack-state)"
  type        = string
  default     = "http://192.168.6.84:8080"
}

variable "scanner_base" {
  description = "scanner-api base (status, r2/state)"
  type        = string
  default     = "http://192.168.6.83:8081"
}

variable "goes_base" {
  description = "goes-archive gallery/API base"
  type        = string
  default     = "http://192.168.6.85:8095"
}

variable "wx_base" {
  description = "wx-alert (SAME/EAS) base on radio-compute"
  type        = string
  default     = "http://192.168.6.84:8090"
}

variable "weather_base" {
  description = "weather-compute Belchertown site base (HEAD for up/down)"
  type        = string
  default     = "http://192.168.6.87"
}

variable "adsb_base" {
  description = "adsb-feeder tar1090/ultrafeeder base"
  type        = string
  default     = "http://192.168.6.86:8080"
}

variable "icecast_base" {
  description = "distribution Icecast base (status-json.xsl)"
  type        = string
  default     = "http://192.168.6.82:8000"
}
