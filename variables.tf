variable "proxmox_user" {
  description = "Proxmox username"
  type        = string
  sensitive   = true
}

variable "proxmox_password" {
  description = "Proxmox password"
  type        = string
  sensitive   = true
}
