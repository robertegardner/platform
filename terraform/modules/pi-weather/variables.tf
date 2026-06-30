# pi-weather — provisions the weather Pi Zero (weather2) as the LOCAL Davis
# collector. weewx keeps collecting + uploading here; the archive DB is replicated
# to the weather-compute LXC via Litestream, which does report-gen + web. Bare
# metal — never destroy/recreate.

variable "weather_host" {
  description = "Hostname/IP of the weather Pi Zero (weather2)"
  type        = string
}

variable "ssh_user" {
  description = "SSH user on weather2 (passwordless sudo for installs/systemctl)"
  type        = string
}

variable "ssh_private_key_path" {
  description = "Private key thebeast's deploy user uses to reach weather2"
  type        = string
}

variable "devices" {
  description = "The weather-domain device subset (the Davis console)"
  type        = any
}

variable "console_mac" {
  description = "Bluetooth MAC of the Davis Vantage console (rfcomm target)"
  type        = string
  default     = "00:1B:DC:50:05:DE"
}

variable "rack_host" {
  description = "weather-compute LXC IP — Litestream SFTP-pushes the replica here"
  type        = string
  default     = "192.168.6.87"
}

variable "replica_path" {
  description = "Path on the rack where Litestream writes the DB replica"
  type        = string
  default     = "/srv/weather-replica"
}

variable "db_path" {
  description = "weewx SQLite archive DB on the Zero (the Litestream source)"
  type        = string
  default     = "/var/lib/weewx/weewx.sdb"
}

variable "litestream_version" {
  description = "Litestream release to install (install-if-absent, arch-matched)"
  type        = string
  default     = "0.3.13"
}

variable "cutover" {
  description = "false = install Litestream idle (the Zero keeps reporting + serving locally). true = switch: DB->WAL, disable the on-Zero Belchertown+Seasons reports, stop the web servers, start Litestream replication. Collection + uploads are never moved (only paused ~seconds for the WAL switch)."
  type        = bool
  default     = false
}
