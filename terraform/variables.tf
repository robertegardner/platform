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

variable "ssh_private_key_path" {
  description = "Private key thebeast's deploy user uses to reach the Pi"
  type        = string
  default     = "~/.ssh/id_ed25519"
}
