module "k8s_cluster" {
  source = "github.com/pixil98/homelab-tfmod-kubernetes.git?ref=main"

  proxmox_user     = var.proxmox_user
  proxmox_password = var.proxmox_password
  proxmox_endpoint = "https://hobbes.lab.reisman.org:8006"

  nodes              = ["hobbes"]
  namespace          = "production"

  kubernetes_controller_ips = [ 
    "192.168.1.21",
    "192.168.1.22",
    "192.168.1.23"
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
  flux_github_token  = var.github_token
  flux_values_json   = file("${path.module}/values.json")
  flux_secrets_json  = file("${path.module}/secrets.json")
  flux_core_branch   = "main"
}
