# 控制面入口：私网 CLB（TCP 6443，挂 3 台 master）
#
# 为什么不用 kube-vip / keepalived：
#   · kube-vip 依赖 ARP 宣告 VIP，keepalived 依赖 VRRP 组播，二者都需要二层广播域；
#   · 阿里云 VPC 是三层网络，广播/组播受限，且 ENI 有源 IP 反欺骗，
#     VIP 作为源地址发出的报文会被平台丢弃，主备切换经常失败；
#   · 行业务要自管 VIP 只能用 HAVIP，配置量并不比 CLB 少。
# CLB 由平台托管四层转发与健康检查，节点上不跑任何 VIP 守护进程；
# kubeadm 的 controlPlaneEndpoint 直接指向 CLB 私网地址。

locals {
  # kubeadm 的 controlPlaneEndpoint 需要 host:port
  apiserver_endpoint = "${alicloud_slb_load_balancer.apiserver.address}:6443"
}

resource "alicloud_slb_load_balancer" "apiserver" {
  load_balancer_name = "${local.name_prefix}-apiserver"
  address_type       = "intranet"
  vswitch_id         = alicloud_vswitch.this.id
  load_balancer_spec = "slb.s1.small"
  payment_type       = "PayAsYouGo"

  tags = merge(local.common_tags, { role = "control-plane-lb" })
}

resource "alicloud_slb_listener" "apiserver" {
  load_balancer_id          = alicloud_slb_load_balancer.apiserver.id
  protocol                  = "tcp"
  frontend_port             = 6443
  backend_port              = 6443
  bandwidth                 = -1 # 私网不限速
  scheduler                 = "wrr"
  health_check              = "on"
  health_check_type         = "tcp"
  health_check_connect_port = 6443
  health_check_interval     = 5
  health_check_timeout      = 3
  healthy_threshold         = 3
  unhealthy_threshold       = 3
}

# 三台 master 都进默认后端组；apiserver 无状态，权重均分即可
resource "alicloud_slb_backend_server" "apiserver" {
  load_balancer_id = alicloud_slb_load_balancer.apiserver.id

  dynamic "backend_servers" {
    for_each = alicloud_instance.master[*].id
    content {
      server_id = backend_servers.value
      weight    = 100
    }
  }
}
