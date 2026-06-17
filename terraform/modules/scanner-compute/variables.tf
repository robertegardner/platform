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
  description = "Scanner-domain devices from the registry (present only) — drives the SoapyRemote client config"
  # `any`, not map(any): registry device objects are heterogeneous, so map()
  # coercion fails to unify them once more than one scanner device is present.
  # The module only iterates with for/keys, which work on an object just as well.
  type = any
}

variable "icecast_host" {
  description = "Rack Icecast host the scanner publishes to (distribution LXC)"
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

variable "whisper_token" {
  description = "Bearer token for the remote faster-whisper host (EMS transcription). Empty leaves transcribe.env for manual fill (keep-if-absent)."
  type        = string
  sensitive   = true
  default     = ""
}
