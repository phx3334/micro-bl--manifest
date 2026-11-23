#`path.module` = 当前这个 .tf 文件所在的目录
#`templatefile`：读取模板 `inventory.tpl`，把后面传入的变量渲染填充，生成最终文本

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
