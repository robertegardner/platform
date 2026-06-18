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

variable "devices" {
  description = "Radio-domain devices from the registry (present only) — drives the SoapyRemote client config"
  # `any`, not map(any): registry device objects are heterogeneous (e.g. dx-r2
  # has _antenna_ports + sample_rate_max; hf-plus does not), so map() coercion
  # fails to unify them once more than one radio device is present. The module
  # only iterates with for/keys, which work on an object just as well.
  type = any
}

variable "wxsat_devices" {
  description = "Weather-sat (Meteor LRPT) devices from the registry (present only). Expected: the Nooelec on p24, served over rtl_tcp. Drives the rack wxsat scheduler/capture. Empty disables the wxsat block. `any` for the same heterogeneity reason as `devices`."
  type        = any
  default     = {}
}

variable "icecast_host" {
  description = "Rack Icecast host the radio domain publishes to (distribution LXC)"
  type        = string
}

variable "pi_host" {
  description = "Acquisition Pi host (resolves from this LXC) — the rack tuner proxies wxsat (Pi-side captures) to its UI on :8080"
  type        = string
}

variable "icecast_port" {
  description = "Rack Icecast port"
  type        = number
  default     = 8000
}

variable "icecast_source_password" {
  description = "Icecast source-client password"
  type        = string
  sensitive   = true
}
