variable "pi_host" {
  description = "Hostname/IP of the radio acquisition Pi"
  type        = string
}

variable "ssh_user" {
  description = "SSH user on the Pi (passwordless sudo)"
  type        = string
}

variable "ssh_private_key_path" {
  description = "Private key used to SSH into the Pi"
  type        = string
}

variable "devices" {
  description = "Present devices from the registry (map id => device object)"
  type        = any
}
