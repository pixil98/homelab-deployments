terraform {
  required_providers {
    proxmox = {
      source = "Telmate/proxmox"
      version = "2.9.13"
    }
  }
}

provider "proxmox" {
  pm_api_url = "https://hobbes.lab.reisman.org:8006/api2/json"
  pm_parallel = 1
  pm_user = var.proxmox_user
  pm_password = var.proxmox_password
}
