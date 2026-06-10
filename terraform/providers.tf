terraform {
  required_version = ">= 1.5"

  required_providers {
    # bpg/proxmox — the actively maintained provider (NOT Telmate). Native API
    # token support + full LXC support. Copied from homelab-monitor's pattern.
    proxmox = {
      source  = "bpg/proxmox"
      version = "~> 0.66"
    }
  }
}

# The pi-acquisition module (this phase) creates NO Proxmox resources — it is a
# null_resource + remote-exec to the bare-metal Pi. The provider is configured
# here for the compute/distribution modules that land in later phases. Provider
# config is lazy: no API call is made unless a Proxmox resource is touched.
provider "proxmox" {
  endpoint  = var.pm_api_url
  api_token = "${var.pm_api_token_id}=${var.pm_api_token_secret}"
  insecure  = var.pm_tls_insecure
}
