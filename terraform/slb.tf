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
