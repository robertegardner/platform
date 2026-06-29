# --- Proxmox connection (used by compute/distribution modules in later phases;
#     declared now so the provider config and tfvars are stable). ----------------
variable "pm_api_url" {
  description = "Proxmox API URL e.g. https://192.168.6.163:8006/api2/json"
  type        = string
}

variable "pm_api_token_id" {
  description = "Proxmox API token id e.g. deploy@pve!terraform"
  type        = string
}

variable "pm_api_token_secret" {
  description = "Proxmox API token secret (UUID)"
  type        = string
  sensitive   = true
}

variable "pm_node" {
  description = "Proxmox node name (thebeast)"
  type        = string
}

variable "pm_tls_insecure" {
  description = "Skip TLS verification against the Proxmox API"
  type        = bool
  default     = true
}

# --- LXC base config (compute/distribution containers) ------------------------
variable "vmid_base" {
  description = "Base vmid for platform LXCs (900+; homelab-monitor owns 800-820)"
  type        = number
  default     = 900
}

variable "lxc_template" {
  description = "LXC template file id"
  type        = string
  default     = "local:vztmpl/ubuntu-24.04-standard_24.04-2_amd64.tar.zst"
}

variable "lxc_storage" {
  description = "Datastore for LXC root disks"
  type        = string
  default     = "local-lvm"
}

variable "pve_bridge" {
  description = "Proxmox bridge"
  type        = string
  default     = "vmbr0"
}

variable "pool_name" {
  description = "Proxmox resource pool for platform LXCs"
  type        = string
  default     = "platform"
}

variable "vlan_server" {
  description = "Server VLAN id — native untagged, MUST stay 0 (never 1)"
  type        = number
  default     = 0
}

variable "gw_server" {
  description = "Server VLAN gateway"
  type        = string
  default     = "192.168.6.1"
}

variable "prefix" {
  description = "Server VLAN prefix length"
  type        = number
  default     = 24
}

variable "ssh_public_key" {
  description = "Public key injected as the LXC root authorized key (deploy's key)"
  type        = string
}

# --- Distribution tier (rack Icecast) ------------------------------------------
variable "distribution_ip" {
  description = "Static IP of the distribution LXC (platform block .82+)"
  type        = string
  default     = "192.168.6.82"
}

variable "icecast_hostname" {
  description = "Public hostname Icecast advertises in listen URLs"
  type        = string
  default     = "icecast.rg2.io"
}

variable "icecast_source_password" {
  description = "Icecast source-client password (reuses the Pi's existing one)"
  type        = string
  sensitive   = true
}

variable "whisper_token" {
  description = "Bearer token for the remote faster-whisper host (scanner EMS transcription; same token as the radio captions). Empty leaves transcribe.env for manual fill (it is keep-if-absent)."
  type        = string
  sensitive   = true
  default     = ""
}

variable "icecast_admin_password" {
  description = "Icecast admin UI password"
  type        = string
  sensitive   = true
}

# --- Compute tier (rack LXCs) --------------------------------------------------
variable "scanner_compute_ip" {
  description = "Static IP of the scanner-compute LXC"
  type        = string
  default     = "192.168.6.83"
}

variable "radio_compute_ip" {
  description = "Static IP of the radio-compute LXC"
  type        = string
  default     = "192.168.6.84"
}

# --- Pi acquisition node (bare metal, SSH target) -----------------------------
variable "pi_host" {
  description = "Hostname/IP of the radio acquisition Pi (resolves from thebeast)"
  type        = string
  default     = "radio.srvr"
}

variable "pi_ssh_user" {
  description = "SSH user on the Pi (passwordless sudo for apt/systemctl)"
  type        = string
  default     = "rgardner"
}

# --- Weather-sat acquisition node (outdoor ADS-B Pi, p24) ---------------------
variable "wxsat_host" {
  description = "Hostname/IP of the outdoor ADS-B Pi hosting the Nooelec/Meteor dipole. Use the IP since p24.srvr may not resolve from thebeast."
  type        = string
  default     = "192.168.6.141"
}

variable "wxsat_ssh_user" {
  description = "SSH user on p24 (passwordless sudo for installs/systemctl)"
  type        = string
  default     = "rgardner"
}

# --- GOES acquisition + decode node (dedicated Pi 5, goes.srvr) ---------------
variable "goes_host" {
  description = "Hostname/IP of the GOES Pi. Use the IP since goes.srvr may not resolve from thebeast/LXC."
  type        = string
  default     = "192.168.6.134"
}

variable "goes_ssh_user" {
  description = "SSH user on the GOES Pi (passwordless sudo for installs/systemctl)"
  type        = string
  default     = "rgardner"
}

variable "goes_archive_ip" {
  description = "Static IP of the goes-archive LXC (vmid_base+3)"
  type        = string
  default     = "192.168.6.85"
}

# --- ADS-B acquisition node (standalone outdoor Pi, p24) ----------------------
variable "adsb_host" {
  description = "Hostname/IP of the ADS-B decoder Pi (p24). Use the IP since p24.srvr may not resolve from thebeast/LXC."
  type        = string
  default     = "192.168.6.141"
}

variable "adsb_ssh_user" {
  description = "SSH user on p24 (passwordless sudo for installs/systemctl)"
  type        = string
  default     = "rgardner"
}

variable "adsb_feeder_ip" {
  description = "Static IP of the adsb-feeder LXC (vmid_base+4)"
  type        = string
  default     = "192.168.6.86"
}

variable "ssh_private_key_path" {
  description = "Private key thebeast's deploy user uses to reach the Pi"
  type        = string
  default     = "~/.ssh/id_ed25519"
}
