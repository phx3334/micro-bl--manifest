#`path.module` = 当前这个 .tf 文件所在的目录
#`templatefile`：读取模板 `inventory.tpl`，把后面传入的变量渲染填充，生成最终文本

resource "local_file" "ansible_inventory" {
  filename = "${path.module}/../ansible/inventory/hosts.ini"

  content = templatefile("${path.module}/templates/inventory.tpl", {
    masters = [
      for i in range(var.master_count) : {
        name = "k8s-master-${i + 1}"
        # ansible_host 用实例自身公网 IP：Ansible 必须按主机寻址，
        # 不能用 EIP（SLB wrr 会把连接分到不同 master，见 eip.tf）
        public_ip  = alicloud_instance.master[i].public_ip
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
    # 统一公网入口（EIP，绑 SLB）：Harbor externalURL、证书 SAN、
    # containerd registry 地址、REPLACE_WITH_SERVER_IP 都用它
    entry_ip = alicloud_eip.entry.ip_address
  })
}
