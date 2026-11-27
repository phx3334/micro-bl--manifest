output "master_public_ips" {
  description = "控制节点公网 IP（实例自动分配，仅供 Ansible 按主机 SSH；对外入口用 entry_eip）"
  value       = alicloud_instance.master[*].public_ip
}

output "entry_eip" {
  description = "统一公网入口 EIP（绑定 apiserver SLB）：SSH/kubectl/NodePort 服务、REPLACE_WITH_SERVER_IP、证书 IP SAN 都指向它"
  value       = alicloud_eip.entry.ip_address
}

output "public_slb_address" {
  description = "公网业务/媒体入口（浏览器访问与 Cloudflare 回源都指向它）"
  value       = alicloud_slb_load_balancer.public.address
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

output "csi_ram_role_name" {
  description = "阿里云云盘 CSI 使用的实例 RAM 角色"
  value       = alicloud_ram_role.csi.role_name
}

output "ansible_inventory" {
  description = "自动生成的 ansible inventory 路径"
  value       = local_file.ansible_inventory.filename
}

output "ssh_hint" {
  description = "登录提示（EIP 经 SLB 落到任一存活 master；连指定 master 用 master_public_ips）"
  value       = "ssh -i <你的私钥> root@${alicloud_eip.entry.ip_address}"
}
