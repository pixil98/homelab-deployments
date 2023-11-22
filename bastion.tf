module "bastion" {
  source = "git@github.com:pixil98/homelab-tfmod-vm.git?ref=main"

  node      = "hobbes"
  namespace = proxmox_virtual_environment_pool.infrastructure.pool_id

  vm_name            = "bastion"
  vm_description     = "Bastion host"
  vm_cpu_cores       = 1
  vm_cpu_sockets     = 1
  vm_memory          = 2048
  vm_disk_size       = "20G"
  vm_disk_class      = "local-zfs"
  vm_network_address = "192.168.1.3"
  vm_user            = "aaron"
  vm_user_privatekey = file("~/.ssh/id_ed25519")
  
  puppet_role    = "base"
}
