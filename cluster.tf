module "k8s_cluster" {
  source = "github.com/pixil98/homelab-tfmod-kubernetes.git?ref=initial-flux"

  nodes              = ["luke", "flip"]
  namespace          = "production"
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

  flux_enabled       = true
  flux_github_branch = "production"
  flux_github_token  = var.github_token

  sealed_secrets_key = file(var.sealed_secrets_key)
  sealed_secrets_crt = file(var.sealed_secrets_crt)
}
