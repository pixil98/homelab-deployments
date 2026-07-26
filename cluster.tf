module "k8s_cluster" {
  source = "github.com/pixil98/homelab-tfmod-kubernetes.git?ref=main"

  proxmox_user     = var.proxmox_user
  proxmox_password = var.proxmox_password
  proxmox_endpoint = "https://hobbes.lab.reisman.org:8006"

  nodes     = ["hobbes"]
  namespace = "ugre"

  kubernetes_controller_ips = [
    "192.168.1.50"
  ]

  kubernetes_worker_ips = [
    "192.168.1.51",
    "192.168.1.52",
    "192.168.1.53"
  ]

  flux_enabled      = true
  flux_github_token = var.github_token
  flux_values_json  = file("${path.module}/values.json")
  flux_secrets_json = file("${path.module}/secrets.json")
  flux_core_branch  = "main"
  flux_core_path    = "./profiles/ugre"

  infrastructure_gateway_registration_enabled = true
}
