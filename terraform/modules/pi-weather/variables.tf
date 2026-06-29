# pi-weather — provisions the weather Pi Zero (weather2) as a THIN bridge: the
# Davis Vantage console (Bluetooth rfcomm → /dev/rfcomm0) re-served as a raw
# serial-over-TCP port (ser2net) for the rack weewx. The heavy weewx/report/web
# load moves to the weather-compute LXC. Bare metal — never destroy/recreate.

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
  description = "The weather-domain device subset (the Davis console / bridge)"
  type        = any
}

variable "console_mac" {
  description = "Bluetooth MAC of the Davis Vantage console (rfcomm target)"
  type        = string
  default     = "00:1B:DC:50:05:DE"
}

variable "ser2net_port" {
  description = "TCP port ser2net exposes /dev/rfcomm0 on (the Vantage serial)"
  type        = number
  default     = 3001
}

variable "cutover" {
  description = "false = install the bridge but leave it idle (local weewx keeps the console). true = perform the switch: stop local weewx + the 3 web servers, take over rfcomm, start ser2net. Flip to true only at the coordinated cutover."
  type        = bool
  default     = false
}
