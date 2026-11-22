resource "local_file" "ansible_inventory" {
  filename = "${path.module}/../ansible/inventory/hosts.ini"

  content = templatefile("${path.module}/templates/inventory.tpl", {
    masters = [
      for i, ip in alicloud_instance.master[*].public_ip : {
        name       = "k8s-master-${i + 1}"
        public_ip  = ip
        private_ip = local.master_private_ips[i]
      }
    ]
    workers = [
      for i, ip in alicloud_instance.worker[*].public_ip : {
        name       = "k8s-worker-${i + 1}"
        public_ip  = ip
        private_ip = local.worker_private_ips[i]
      }
    ]
    apiserver_endpoint = local.apiserver_endpoint
  })
}
