output "master_public_ips" {
  description = "控制节点公网 IP"
  value       = alicloud_instance.master[*].public_ip
}

output "worker_public_ips" {
  description = "工作节点公网 IP"
  value       = alicloud_instance.worker[*].public_ip
}

output "node_private_ips" {
  description = "节点私网 IP（kubeadm 使用）"
  value = {
    masters = local.master_private_ips
    workers = local.worker_private_ips
  }
}

output "apiserver_endpoint" {
  description = "控制面入口（私网 CLB host:port，kubeadm controlPlaneEndpoint 使用）"
  value       = local.apiserver_endpoint
}

output "security_group_id" {
  description = "节点安全组 ID"
  value       = alicloud_security_group.this.id
}

output "ansible_inventory" {
  description = "自动生成的 ansible inventory 路径"
  value       = local_file.ansible_inventory.filename
}

output "ssh_hint" {
  description = "登录提示"
  value       = "ssh -i <你的私钥> root@${alicloud_instance.master[0].public_ip}"
}
