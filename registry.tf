module "registry" {
  source = "git@github.com:pixil98/homelab-tfmod-vm.git?ref=main"

  node      = "hobbes"
  namespace = proxmox_pool.infrastructure.poolid

  vm_name            = "registry"
  vm_description     = "Container pull through registry"
  vm_cpu_cores       = 1
  vm_cpu_sockets     = 1
  vm_memory          = 4096
  vm_disk_size       = "30G"
  vm_disk_class      = "local-zfs"
  vm_network_address = "192.168.1.11"
  vm_user            = "aaron"
  vm_user_publickey  = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPxIRM7Qz5XOAGbtkaTlP/GdP/w6Pr4UzqYlXXrwJ+4a aaron@reisman.org"
  vm_user_privatekey = file("~/.ssh/id_ed25519")
  
  puppet_git_ref = "initial-dev"
  puppet_role    = "docker_registry"
}
