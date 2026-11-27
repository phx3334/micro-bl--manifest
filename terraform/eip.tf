# 集群统一公网入口：EIP 绑定内网 apiserver SLB（不再绑 master1 实例）。
# SLB 健康检查在 master 间自动摘除故障节点，消除"master1 单点导致入口全断"：
#   EIP:6443 → kubectl；EIP:22 → SSH（落到任一存活 master）；
#   EIP:<NodePort> → Harbor/ArgoCD/Grafana/MinIO/业务站（监听见 slb.tf）。
# 地址本身不变：REPLACE_WITH_SERVER_IP、证书 IP SAN 继续指向它（Cloudflare
# 回源与浏览器443 走公网 SLB，见 slb.tf，不经此 EIP）。
# 按流量计费：bandwidth 只是突发上限。
#
# 注意：Ansible 按主机寻址必须走各节点自己的公网 IP（见 inventory.tf），
# 不能让 inventory 用 EIP——SLB 四层 wrr 会把连接分到不同 master。
# instance_id 以 lb- 开头时 provider 自动按 SlbInstance 类型绑定。
resource "alicloud_eip" "entry" {
  address_name         = "${local.name_prefix}-entry-eip"
  payment_type         = "PayAsYouGo"
  internet_charge_type = "PayByTraffic"
  bandwidth            = var.internet_max_bandwidth_out

  tags = local.common_tags
}

resource "alicloud_eip_association" "entry" {
  allocation_id = alicloud_eip.entry.id
  instance_id   = alicloud_slb_load_balancer.apiserver.id
}
