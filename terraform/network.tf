resource "alicloud_vpc" "this" {
  vpc_name    = "${local.name_prefix}-vpc"
  cidr_block  = var.vpc_cidr
  description = "micro-bl k8s (terraform)"

  tags = local.common_tags
}

resource "alicloud_vswitch" "this" {
  vswitch_name = "${local.name_prefix}-vsw"
  vpc_id       = alicloud_vpc.this.id
  cidr_block   = var.vswitch_cidr
  zone_id      = local.az

  tags = local.common_tags
}

resource "alicloud_security_group" "this" {
  security_group_name = "${local.name_prefix}-k8s"
  description         = "micro-bl k8s nodes"
  vpc_id              = alicloud_vpc.this.id

  tags = local.common_tags
}

# VPC 内全通：etcd 2379/2380、kubelet 10250、Cilium VXLAN、NodePort 互访都依赖它
resource "alicloud_security_group_rule" "internal_all" {
  type              = "ingress"
  ip_protocol       = "all"
  port_range        = "-1/-1"
  priority          = 1
  security_group_id = alicloud_security_group.this.id
  cidr_ip           = var.vpc_cidr
}

resource "alicloud_security_group_rule" "ssh" {
  type              = "ingress"
  ip_protocol       = "tcp"
  port_range        = "22/22"
  priority          = 2
  security_group_id = alicloud_security_group.this.id
  cidr_ip           = var.ssh_cidr
}

# apiserver：只对运维来源开放（本机 kubectl 直连 master），不暴露给全网
resource "alicloud_security_group_rule" "apiserver" {
  type              = "ingress"
  ip_protocol       = "tcp"
  port_range        = "6443/6443"
  priority          = 3
  security_group_id = alicloud_security_group.this.id
  cidr_ip           = var.ssh_cidr
}

# CLB 健康检查的源地址固定为 100.64.0.0/10（阿里云保留段，不在 VPC 网段内）。
# 少这一条的表现：CLB 后端永远"异常"，kubeadm 初始化卡在等待 controlPlaneEndpoint。
resource "alicloud_security_group_rule" "clb_health_check" {
  type              = "ingress"
  ip_protocol       = "tcp"
  port_range        = "6443/6443"
  priority          = 4
  security_group_id = alicloud_security_group.this.id
  cidr_ip           = "100.64.0.0/10"
}

# 公网 SLB 的健康检查同样源自 100.64.0.0/10，探测后端 NodePort 30443（HTTPS）。
# 少这一条的表现：公网入口 443 全部 503（后端全部被判不健康）。
resource "alicloud_security_group_rule" "public_slb_health_check" {
  type              = "ingress"
  ip_protocol       = "tcp"
  port_range        = "30443/30443"
  priority          = 5
  security_group_id = alicloud_security_group.this.id
  cidr_ip           = "100.64.0.0/10"
}

# EIP 入口监听（见 slb.tf 的 entry_listeners）健康检查同样源自 100.64.0.0/10，
# 探测 SSH 与各 NodePort（30080 = HTTP 直连入口也在内）。
# 少这些条的表现：EIP 对应端口全部连不上（后端被判不健康）。
resource "alicloud_security_group_rule" "entry_slb_health_check" {
  for_each = toset(["22", "30003", "30080", "30081", "30082", "30300", "30400", "30900"])

  type              = "ingress"
  ip_protocol       = "tcp"
  port_range        = "${each.value}/${each.value}"
  priority          = 6
  security_group_id = alicloud_security_group.this.id
  cidr_ip           = "100.64.0.0/10"
}

# Cloudflare CDN 回源：边缘节点源 IP 落在这些段（官方清单 https://www.cloudflare.com/ips/），
# 回源目标是公网 SLB:443 → 后端 NodePort 30443。CLB 四层保留客户端源 IP，
# 所以后端安全组看到的是 Cloudflare 边缘 IP，必须单独放行，否则 CDN 开橙云后全 522。
# 只放 IPv4（Cloudflare 回源默认走 IPv4）；清单变动时更新此列表。
resource "alicloud_security_group_rule" "cloudflare_origin" {
  for_each = toset([
    "173.245.48.0/20",
    "103.21.244.0/22",
    "103.22.200.0/22",
    "103.31.4.0/22",
    "141.101.64.0/18",
    "108.162.192.0/18",
    "190.93.240.0/20",
    "188.114.96.0/20",
    "197.234.240.0/22",
    "198.41.128.0/17",
    "162.158.0.0/15",
    "104.16.0.0/13",
    "104.24.0.0/14",
    "172.64.0.0/13",
    "131.0.72.0/22",
  ])

  type              = "ingress"
  ip_protocol       = "tcp"
  port_range        = "30443/30443"
  priority          = 7
  security_group_id = alicloud_security_group.this.id
  cidr_ip           = each.value
}

# 外部入口：只保留 prod 真正需要浏览器访问的 NodePort；
# Prometheus / Alertmanager / Tempo 等内部组件保持 ClusterIP，排障走 port-forward。
locals {
  node_ports = toset([
    "30003", # Harbor HTTPS
    "30080", # Istio ingressgateway HTTP（直连 http://IP:30080）
    "30081", # Tekton EventListener
    "30082", # ArgoCD
    "30300", # Grafana
    "30400", # Hubble UI
    "30443", # Istio ingressgateway HTTPS（直连/调试 https://IP:30443）
    "30900", # MinIO API
  ])
}

resource "alicloud_security_group_rule" "nodeports" {
  for_each = local.node_ports

  type              = "ingress"
  ip_protocol       = "tcp"
  port_range        = "${each.value}/${each.value}"
  priority          = 10
  security_group_id = alicloud_security_group.this.id
  cidr_ip           = var.node_port_cidr
}

resource "alicloud_security_group_rule" "egress_all" {
  type              = "egress"
  ip_protocol       = "all"
  port_range        = "-1/-1"
  priority          = 1
  security_group_id = alicloud_security_group.this.id
  cidr_ip           = "0.0.0.0/0"
}
