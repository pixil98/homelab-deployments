terraform {
  required_providers {
    proxmox = {
      source = "bpg/proxmox"
      version = "0.38.1"
    }
  }
}

provider "proxmox" {
  endpoint = "https://hobbes.lab.reisman.org:8006"
  username = var.proxmox_user
  password = var.proxmox_password
}
