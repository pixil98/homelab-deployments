module "k8s_cluster" {
  source = "github.com/pixil98/homelab-tfmod-kubernetes.git?ref=main"

  nodes              = ["luke", "flip"]
  namespace          = "development"
  vm_user            = "aaron"
  vm_user_privatekey = file(var.user_privatekey)

  kubernetes_controller_ips = [
    "192.168.1.40", 
  ]
  kubernetes_worker_ips = [
    "192.168.1.41", 
    "192.168.1.42",
  ]

  flux_enabled       = true
  flux_github_branch = "development"
  flux_github_token  = var.github_token
}
