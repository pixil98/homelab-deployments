module "k8s_cluster" {
  source = "github.com/pixil98/homelab-tfmod-kubernetes.git?ref=main"

  proxmox_user     = var.proxmox_user
  proxmox_password = var.proxmox_password
  proxmox_endpoint = "https://hobbes.lab.reisman.org:8006"

  nodes              = ["luke", "hobbes"]
  namespace          = "prd"
  vm_disk_class      = "local-zfs"
  vm_user            = "aaron"
  vm_user_privatekey = file(var.user_privatekey)

  kubernetes_controller_ips = [
    "192.168.1.20", 
    "192.168.1.21", 
    "192.168.1.22"
  ]

  kubernetes_worker_ips = [
    "192.168.1.30", 
    "192.168.1.31",
    "192.168.1.32",
    "192.168.1.33",
    "192.168.1.34"
  ]

  kubernetes_worker_cpu_cores   = 4
  kubernetes_worker_cpu_sockets = 2
  kubernetes_worker_memory      = 32768
  kubernetes_worker_disk_size   = 50

  flux_enabled       = true
  flux_github_branch = "production"
  flux_github_token  = var.github_token

  sealed_secrets_key = file(var.sealed_secrets_key)
  sealed_secrets_crt = file(var.sealed_secrets_crt)
}
