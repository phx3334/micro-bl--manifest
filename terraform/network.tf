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

# 外部入口：只保留 prod 真正需要浏览器访问的 NodePort；
# Prometheus / Alertmanager / Tempo 等内部组件保持 ClusterIP，排障走 port-forward。
locals {
  node_ports = toset([
    "30003", # Harbor HTTPS
    "30080", # Istio ingressgateway
    "30081", # Tekton EventListener
    "30082", # ArgoCD
    "30300", # Grafana
    "30400", # Hubble UI
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
