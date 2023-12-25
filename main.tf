terraform {
  required_providers {
    proxmox = {
      source = "bpg/proxmox"
      version = "0.42.0"
    }
  }
}

provider "proxmox" {
  endpoint = "https://hobbes.lab.reisman.org:8006"
  username = var.proxmox_user
  password = var.proxmox_password
}
