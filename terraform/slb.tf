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

# ---------------------------------------------------------------------------
# EIP 入口监听（EIP 绑定本 SLB，见 eip.tf）：原先这些端口直连 master1 的 EIP，
# master1 单点；现在经 SLB 分发到健康 master（NodePort 由 Cilium eBPF 全节点转发）。
# 22 走 SLB 后 SSH 落到任一 master，hostname 可辨认；Ansible 仍按节点公网 IP 直连。
# 健康检查源 100.64.0.0/10 的放行见 network.tf。
locals {
  entry_listeners = {
    "22"    = "ssh"
    "30003" = "harbor"
    "30080" = "istio-ingress"
    "30081" = "tekton-webhook"
    "30082" = "argocd"
    "30300" = "grafana"
    "30400" = "hubble"
    "30900" = "minio"
  }
}

resource "alicloud_slb_listener" "entry" {
  for_each = local.entry_listeners

  load_balancer_id          = alicloud_slb_load_balancer.apiserver.id
  protocol                  = "tcp"
  frontend_port             = tonumber(each.key)
  backend_port              = tonumber(each.key)
  bandwidth                 = -1 # 跟随 EIP 带宽上限，不单独限速
  scheduler                 = "wrr"
  health_check              = "on"
  health_check_type         = "tcp"
  health_check_connect_port = tonumber(each.key)
  health_check_interval     = 5
  health_check_timeout      = 3
  healthy_threshold         = 3
  unhealthy_threshold       = 3
}

# ---------------------------------------------------------------------------
# 公网站点/API 入口：浏览器与 Cloudflare CDN 回源都走这里，不再直连节点公网 IP。
# TCP 443 透传到节点 NodePort 30443（Istio Gateway 终止 TLS，证书为
# *.temporary-demo.xyz，cert-manager 自动签发续期），按 Host 分流站点与 API。
# 媒体（视频/封面/头像）不经过本 SLB：MinIO 仍由 NodePort 30900 直连，
# 视频走 CDN 受 Cloudflare 非 Enterprise 计划条款限制，课程实验不接。
# CDN 回源源 IP 是 Cloudflare 边缘段，安全组需单独放行
# （见 network.tf 的 cloudflare_origin）。节点直连的 NodePort 仅保留管理用途。
# 按流量计费，bandwidth 是突发上限，与节点侧 internet_max_bandwidth_out 同变量。
resource "alicloud_slb_load_balancer" "public" {
  load_balancer_name = "${local.name_prefix}-public"
  address_type       = "internet"
  # 必须落在集群 VPC 的交换机内：后端是 VPC 内的 ECS，经典网络实例挂不上 VPC 后端。
  # address_type=internet 时指定 vswitch 不影响分配公网 IP。
  vswitch_id           = alicloud_vswitch.this.id
  load_balancer_spec   = "slb.s1.small"
  payment_type         = "PayAsYouGo"
  internet_charge_type = "PayByTraffic"
  bandwidth            = var.internet_max_bandwidth_out

  tags = merge(local.common_tags, { role = "public-entry" })
}

resource "alicloud_slb_listener" "public_https" {
  load_balancer_id          = alicloud_slb_load_balancer.public.id
  protocol                  = "tcp"
  frontend_port             = 443
  backend_port              = 30443 # → ingressgateway HTTPS（NodePort 30443，TLS 在 Istio 终结）
  bandwidth                 = -1    # 跟随实例带宽上限，不单独限速
  scheduler                 = "wrr"
  health_check              = "on"
  health_check_type         = "tcp"
  health_check_connect_port = 30443
  health_check_interval     = 5
  health_check_timeout      = 3
  healthy_threshold         = 3
  unhealthy_threshold       = 3
}

# 所有节点都进后端组：Cilium eBPF 在每台节点上都转发 NodePort 30443，
# ingressgateway Pod 调度到哪台都能被访问到
resource "alicloud_slb_backend_server" "public" {
  load_balancer_id = alicloud_slb_load_balancer.public.id

  dynamic "backend_servers" {
    for_each = concat(alicloud_instance.master[*].id, alicloud_instance.worker[*].id)
    content {
      server_id = backend_servers.value
      weight    = 100
    }
  }
}
