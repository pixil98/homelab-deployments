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

variable "user_privatekey" {
  description = "Private key to use when provisioning VMs"
  type        = string
  sensitive   = true
}

variable "github_token" {
  description = "Github token"
  type        = string
  sensitive   = true
  default     = ""
}

variable "sealed_secrets_key" {
  description = "Sealed secrets private key"
  type        = string
  sensitive   = true
  default     = ""
}

variable "sealed_secrets_crt" {
  description = "Sealed secrets public certificate"
  type        = string
  sensitive   = true
  default     = ""
}